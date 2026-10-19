defmodule OhMyJido.HostPrivacyTest do
  use Jido.AI.TestCase, async: false
  import ExUnit.CaptureLog

  alias OhMyJido.{CodingAgent, Context, Runtime, Session}

  @moduletag :tmp_dir

  defmodule FailingHost do
    def credentials(_context, _account, opts), do: invoke_failure(opts)
    def authorize(_context, _capability, _effect, opts), do: invoke_failure(opts)
    def invoke(_context, _capability, _request, _opts), do: {:error, :unavailable}
    def question(_context, _question, _opts), do: :pending

    defp invoke_failure(opts) do
      secret = Keyword.fetch!(opts, :secret)

      case Keyword.fetch!(opts, :failure) do
        :throw -> throw({:callback_failed, secret})
        :exit -> exit({:callback_failed, secret})
        :raise -> raise ArgumentError, secret
        :return -> {:error, secret}
      end
    end
  end

  test "credential-service failures remain private before any secret registration", %{
    tmp_dir: root
  } do
    for {failure, name} <- [
          {:throw, __MODULE__.Throw},
          {:exit, __MODULE__.Exit},
          {:raise, __MODULE__.Raise}
        ] do
      secret = "synthetic-credential-callback-#{failure}-013"

      start_supervised!(
        {Runtime,
         name: name, host: {FailingHost, failure: failure, secret: secret}, model: "openai:gpt-4o"}
      )

      {:ok, session} =
        OhMyJido.start_session(name, workspace: root, account: "fixture-account", permissions: [])

      logs =
        capture_log(fn ->
          {:ok, run} = OhMyJido.prompt(session, "Exercise credential service containment")
          assert {:error, %{status: :failed} = result} = OhMyJido.await(session, run)
          assert inspect(result.error) =~ "credential_service_failed"
          refute contains_secret?(result, secret)
          refute contains_secret?(OhMyJido.inspect_session(session), secret)
          refute contains_secret?(OhMyJido.events(session), secret)
        end)

      refute logs =~ secret
      :ok = OhMyJido.stop_session(session)
    end
  end

  test "authorization diagnostics are contained before native Action logging", %{tmp_dir: root} do
    File.write!(Path.join(root, "input.txt"), "unread private fixture")

    for failure <- [:return, :throw, :exit, :raise] do
      secret = "synthetic-authorization-callback-#{failure}-013"

      context = %Context{
        session_id: "authorization-privacy",
        workspace: root,
        permissions: MapSet.new([:read]),
        host: {FailingHost, failure: failure, secret: secret}
      }

      logs =
        capture_log(fn ->
          assert {:error, reason} =
                   Jido.Exec.run(
                     OhMyJido.Tools.Read,
                     %{path: "input.txt"},
                     %{oh_my_jido: context},
                     max_retries: 0
                   )

          refute contains_secret?(reason, secret)
        end)

      refute logs =~ secret
    end
  end

  test "native signed continuation cannot retain a recoverable credential in durable session storage",
       %{
         tmp_dir: root
       } do
    store = Path.join(root, "session-store")
    secret = "synthetic-encoded-continuation-secret-013"

    start_supervised!(
      {Runtime,
       name: __MODULE__.Durable,
       allow_test_scripts: true,
       storage: {Jido.Storage.File, path: store}}
    )

    {:ok, session} = OhMyJido.start_session(__MODULE__.Durable, workspace: root, permissions: [])
    {:ok, context} = Session.call(session, :context)
    :ok = Session.register_secrets(context.coordinator, [secret])

    script =
      expect_react do
        user("Exercise durable continuation privacy")
        answer(secret)
      end

    {:ok, run} =
      OhMyJido.prompt(session, "Exercise durable continuation privacy", react_opts(script))

    assert {:ok, %{status: :completed, answer: answer}} = OhMyJido.await(session, run)
    refute answer =~ secret
    assert {:ok, %{agent_pid: agent_pid}} = OhMyJido.inspect_session(session)
    assert {:ok, %{agent: agent}} = Jido.AgentServer.state(agent_pid)
    assert {:ok, native_checkpoint} = CodingAgent.checkpoint(agent, %{})
    assert Enum.any?(binaries(native_checkpoint), &encoded_secret?(&1, secret))

    :ok = OhMyJido.checkpoint(session)

    assert {:ok, saved} =
             Jido.Storage.File.get_checkpoint({session.runtime, session.id}, path: store)

    refute contains_secret?(saved, secret)
    refute Enum.any?(binaries(saved), &encoded_secret?(&1, secret))
    :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Durable, session.id)
    refute contains_secret?(OhMyJido.inspect_session(session), secret)
  end

  defp contains_secret?(value, secret),
    do: :binary.match(:erlang.term_to_binary(value), secret) != :nomatch

  defp binaries(value) when is_binary(value), do: [value]
  defp binaries(%_{} = value), do: value |> Map.from_struct() |> binaries()

  defp binaries(value) when is_map(value),
    do: Enum.flat_map(value, fn {key, item} -> binaries(key) ++ binaries(item) end)

  defp binaries(value) when is_list(value), do: Enum.flat_map(value, &binaries/1)
  defp binaries(value) when is_tuple(value), do: value |> Tuple.to_list() |> binaries()
  defp binaries(_value), do: []

  defp encoded_secret?("rt2." <> rest, secret) do
    with [payload, _signature] <- String.split(rest, ".", parts: 2),
         {:ok, encoded} <- Base.url_decode64(payload, padding: false) do
      contains_secret?(:erlang.binary_to_term(encoded, [:safe]), secret)
    else
      _invalid -> false
    end
  rescue
    ArgumentError -> false
  end

  defp encoded_secret?(_value, _secret), do: false
end
