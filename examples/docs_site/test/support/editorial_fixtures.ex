defmodule OhMyJidoDocsWeb.EditorialFixtures do
  @moduledoc false

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias OhMyJido.Runtime
  alias OhMyJidoDocs.{Content, Editor, Repo}
  alias OhMyJidoDocs.Editor.Run

  @runtime OhMyJidoDocs.Coding
  @completion_timeout 15_000

  def configure_operator do
    configure(%{
      editor_enabled: true,
      operator_username: "editor-test",
      operator_password_hash: Pbkdf2.hash_pwd_salt("private-test-password", rounds: 4)
    })
  end

  def source_fixture do
    root = Path.join(System.tmp_dir!(), "docs-web-#{Ecto.UUID.generate()}")
    source = Path.join(root, "source")
    app = Path.join(source, "examples/docs_site")
    File.mkdir_p!(Path.join(app, "priv/docs"))
    File.mkdir_p!(Path.join(app, "lib"))

    File.write!(
      Path.join(app, "priv/docs/index.md"),
      "# Published guide\n\nOriginal published content.\n"
    )

    File.write!(Path.join(app, "lib/source.ex"), "defmodule EditorialFixture, do: nil\n")

    File.write!(
      Path.join(app, "mix.exs"),
      "defmodule EditorialFixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :editorial_fixture, version: \"0.1.0\"]\nend\n"
    )

    File.write!(
      Path.join(source, "mix.exs"),
      "defmodule EditorialRoot.MixProject do\n  use Mix.Project\n  def project, do: [app: :editorial_fixture_root, version: \"0.1.0\"]\nend\n"
    )

    git!(source, ["init", "--quiet"])
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Editorial Test",
      "-c",
      "user.email=editor@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "Initial source"
    ])

    configure(%{
      source_root: source,
      source_app_path: "examples/docs_site",
      data_dir: Path.join(root, "data"),
      published_root: Path.join(root, "published"),
      static_docs_root: Path.join(app, "priv/docs"),
      model: "anthropic:claude-haiku-4-5",
      model_api_key: nil,
      model_account: "docs-site"
    })

    Content.bootstrap!()
    on_exit(fn -> :ok = OhMyJidoDocs.Candidates.Source.remove_tree(root) end)
    on_exit(fn -> :ok = OhMyJidoDocs.DataCase.stop_private_workers() end)
    %{root: root, source: source, app: app}
  end

  def scripted_runtime(root) do
    {:ok, original} = Runtime.config(@runtime)

    options =
      Keyword.merge(original,
        name: @runtime,
        allow_test_scripts: true,
        max_active: 2,
        max_sessions: 8,
        max_processes: 2,
        context_policy: [max_messages: 80, keep_recent: 80, max_bytes: 256_000],
        storage: {Jido.Storage.File, path: Path.join(root, "sessions")}
      )

    :ok = OhMyJidoDocs.DataCase.restart_private_workers(options)

    on_exit(&settle_scripted_runtime/0)
  end

  defp settle_scripted_runtime do
    Enum.each(Editor.list_runs(), &settle_scripted_run/1)
    sessions = if Process.whereis(@runtime), do: OhMyJido.list_sessions(@runtime), else: []
    Enum.each(sessions, &settle_scripted_session/1)
  end

  defp settle_scripted_run(run) do
    if run.status in ~w(queued running waiting) do
      assert Editor.cancel_run(run.id) in [:ok, {:error, :run_not_active}]
    end

    await_snapshot(run.id, &scripted_run_settled?/1)
  end

  defp scripted_run_settled?(snapshot) do
    snapshot.run.status not in ~w(queued running waiting cancelling suspending) and
      not snapshot.run.source_writer_pending and is_nil(snapshot.run.source_writer_token) and
      not snapshot.run.workspace_cleanup_pending
  end

  defp settle_scripted_session(session) do
    assert :ok = OhMyJido.stop_session(session)

    case Repo.get_by(Run, session_id: session.id) do
      %Run{source_writer_pending: true} = run ->
        assert :ok =
                 Editor.reconcile_writer(
                   run.id,
                   run.source_writer_token,
                   :orphan_resources_reconciled
                 )

      _settled ->
        :ok
    end
  end

  def configure(settings) do
    previous =
      Map.new(settings, fn {key, _value} ->
        {key, Application.fetch_env(:oh_my_jido_docs, key)}
      end)

    Enum.each(settings, fn {key, value} -> Application.put_env(:oh_my_jido_docs, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:oh_my_jido_docs, key, value)
        {key, :error} -> Application.delete_env(:oh_my_jido_docs, key)
      end)
    end)
  end

  def sign_in(conn) do
    Phoenix.ConnTest.dispatch(conn, OhMyJidoDocsWeb.Endpoint, :post, "/login", %{
      "login" => %{"username" => "editor-test", "password" => "private-test-password"}
    })
    |> Phoenix.ConnTest.recycle()
  end

  def stored_run(attrs \\ %{}) do
    Repo.insert!(
      struct!(
        Run,
        Map.merge(
          %{
            task: "Private source request",
            mode: "docs",
            session_id: Ecto.UUID.generate(),
            status: "completed"
          },
          attrs
        )
      )
    )
  end

  def await_snapshot(id, predicate) do
    Editor.subscribe(id)
    await_snapshot(id, predicate, System.monotonic_time(:millisecond) + @completion_timeout)
  end

  defp await_snapshot(id, predicate, deadline) do
    snapshot = Editor.snapshot(id)

    cond do
      predicate.(snapshot) ->
        snapshot

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Native run did not reach the expected state: #{inspect(snapshot.run.status)}")

      true ->
        receive do
          {:docs_run_updated, ^id} -> :ok
        after
          25 -> :ok
        end

        await_snapshot(id, predicate, deadline)
    end
  end

  # A durable snapshot can precede LiveView's host-action completion. Wait for
  # the operator-visible result under the same existing native completion bound.
  def await_studio(view, predicate \\ fn _view -> true end) do
    await_studio(view, predicate, System.monotonic_time(:millisecond) + @completion_timeout)
  end

  defp await_studio(view, predicate, deadline) do
    cond do
      not Phoenix.LiveViewTest.has_element?(view, "#host-action") and predicate.(view) ->
        view

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Studio did not render the expected host result")

      true ->
        receive do
        after
          25 -> await_studio(view, predicate, deadline)
        end
    end
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
  end
end
