defmodule OhMyJidoDocs.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Database changes are sandboxed and rolled back after each test. Synchronous
  cases also own the application's real private worker subtree: it starts after
  the shared sandbox owner and stops before that owner is released. Test fixture
  `on_exit` callbacks run first, so source/process cleanup still has its database
  and workers. Asynchronous database cases do not start singleton private owners.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias OhMyJidoDocs.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import OhMyJidoDocs.DataCase
    end
  end

  setup tags do
    OhMyJidoDocs.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the database owner and, for synchronous cases, its private workers.
  The signature is shared with ConnCase; callers must not enable automatic
  sandbox checkout for background processes.
  """
  def setup_sandbox(tags) do
    # Native build cases already declare their finite ExUnit deadline; a second,
    # shorter Sandbox timer must not revoke ownership during those actual builds.
    ownership_timeout = tags[:timeout] || ExUnit.configuration()[:timeout]

    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(OhMyJidoDocs.Repo,
        shared: not tags[:async],
        ownership_timeout: ownership_timeout
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    unless tags[:async] do
      root = Path.join(System.tmp_dir!(), "docs-private-owner-#{Ecto.UUID.generate()}")

      previous =
        Map.new([:data_dir, :published_root], &{&1, Application.fetch_env(:oh_my_jido_docs, &1)})

      File.mkdir_p!(root)
      File.chmod!(root, 0o700)
      Application.put_env(:oh_my_jido_docs, :data_dir, root)
      Application.put_env(:oh_my_jido_docs, :published_root, Path.join(root, "published"))

      on_exit(fn ->
        try do
          :ok = OhMyJidoDocs.Candidates.Source.remove_tree(root)
        after
          restore_private_settings(previous)
        end
      end)

      OhMyJidoDocs.Content.bootstrap!()

      start_private_workers(OhMyJidoDocs.Application.private_worker_specs())
    end

    :ok
  end

  def private_workers_supervisor, do: OhMyJidoDocs.TestPrivateWorkers

  @doc """
  Applies fixture runtime options without reversing private shutdown ownership.

  Re-adding only the native runtime makes it the last-started child, so it dies
  before the observer can obtain its strong stop receipt. Rebuild the idle
  fixture subtree in its real application order instead.
  """
  def restart_private_workers(runtime_options) do
    :ok = stop_private_workers()

    children =
      Enum.map(OhMyJidoDocs.Application.private_worker_specs(), fn
        {OhMyJido, _options} -> {OhMyJido.Runtime, runtime_options}
        child -> child
      end)

    start_private_workers(children)
  end

  defp start_private_workers(children) do
    {:ok, supervisor} =
      Supervisor.start_link(children,
        strategy: :one_for_one,
        name: private_workers_supervisor()
      )

    Process.unlink(supervisor)
    on_exit(&stop_private_workers/0)
    :ok
  end

  defp restore_private_settings(previous) do
    Enum.each(previous, fn
      {key, {:ok, value}} -> Application.put_env(:oh_my_jido_docs, key, value)
      {key, :error} -> Application.delete_env(:oh_my_jido_docs, key)
    end)
  end

  def stop_private_workers do
    case Process.whereis(private_workers_supervisor()) do
      nil -> :ok
      supervisor -> stop_private_workers(supervisor)
    end
  end

  defp stop_private_workers(supervisor) do
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, :infinity), else: :ok
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
