defmodule OhMyJido.EvalBridgeTest do
  use ExUnit.Case, async: true

  alias OhMyJido.Context
  alias OhMyJido.Eval.Bridge

  defmodule WaitingTool do
    use Jido.Action,
      name: "bridge_wait",
      description: "An observable deadline-bound bridge effect",
      schema: Zoi.object(%{})

    def capability, do: :read

    @impl true
    def run(_parameters, %{oh_my_jido: context} = execution_context) do
      with :ok <- OhMyJido.Tool.authorize(execution_context, :read) do
        send(context.metadata.observer, {:bridge_effect, self()})

        receive do
          :release -> {:ok, %{released: true}}
        end
      end
    end
  end

  defmodule ErrorTool do
    use Jido.Action,
      name: "bridge_error",
      description: "Returns a credential-shaped failure at the tool boundary",
      schema: Zoi.object(%{})

    def capability, do: :read

    @impl true
    def run(_parameters, context) do
      with :ok <- OhMyJido.Tool.authorize(context, :read) do
        {:error, "fixture-secret-value"}
      end
    end
  end

  setup do
    tasks = start_supervised!({Task.Supervisor, []})
    bridge = start_supervised!({Bridge, owner: self(), tasks: tasks, callback_timeout: 250})

    context = %Context{
      session_id: "bridge-unit",
      workspace: System.tmp_dir!(),
      permissions: MapSet.new([:read]),
      tools: [WaitingTool, ErrorTool],
      metadata: %{observer: self(), secrets: ["fixture-secret-value"]}
    }

    request = %{id: "fresh-execution", generation: 7, timeout: 5_000, output_limit: 256}
    assert :ok = Bridge.activate(bridge, context, request)
    %{bridge: bridge, context: context}
  end

  test "unknown operations, arbitrary MFA and stale identities cannot dispatch host effects", %{
    bridge: bridge
  } do
    for operation <- [
          {:rpc, "erlang", "halt", []},
          {:send, :init, :stop},
          {:tool, "unknown_registered_name", %{}},
          {:tool, "eval", %{}}
        ] do
      assert %{"ok" => false} = Bridge.call(bridge, 7, "fresh-execution", operation)
    end

    assert %{"ok" => false, "error" => stale} =
             Bridge.call(bridge, 6, "fresh-execution", {:tool, "bridge_wait", %{}})

    assert stale =~ "stale_execution"

    assert %{"ok" => false} =
             Bridge.call(bridge, 7, "previous-execution", {:tool, "bridge_wait", %{}})

    refute_receive {:bridge_effect, _pid}
  end

  test "a registered secret split across writes is never reassembled unredacted", %{
    bridge: bridge
  } do
    for text <- ["fixture-", "secret-", "value"] do
      assert :ok = Bridge.call(bridge, 7, "fresh-execution", {:output, :stdout, text, false})
    end

    result = Bridge.finish(bridge, %{status: :ok, display: ""})
    assert result.stdout == "[REDACTED]"
  end

  test "bounded output, displays, artifacts and errors share one redacted budget", %{
    bridge: bridge
  } do
    assert :ok =
             Bridge.call(
               bridge,
               7,
               "fresh-execution",
               {:output, :stdout, "fixture-secret-value", false}
             )

    assert :ok = Bridge.call(bridge, 7, "fresh-execution", {:display, "displayed"})

    assert :ok =
             Bridge.call(
               bridge,
               7,
               "fresh-execution",
               {:artifact, "answer.txt", "text/plain", "42"}
             )

    assert %{"ok" => false} =
             Bridge.call(
               bridge,
               7,
               "fresh-execution",
               {:artifact, "../escape", "text/plain", "x"}
             )

    assert :ok =
             Bridge.call(
               bridge,
               7,
               "fresh-execution",
               {:output, :stderr, String.duplicate("x", 1_000), false}
             )

    result =
      Bridge.finish(bridge, %{status: :error, display: "final", error: "fixture-secret-value"})

    assert result.truncated
    assert result.stdout == "[REDACTED]"
    assert result.displays == ["displayed"]
    assert [%{name: "answer.txt", data: "42"}] = result.artifacts

    assert byte_size(result.stdout) + byte_size(result.stderr) + byte_size(result.display) +
             byte_size(result.error) + Enum.sum(Enum.map(result.displays, &byte_size/1)) +
             Enum.sum(Enum.map(result.artifacts, &byte_size(&1.data))) <= 256

    refute inspect(result) =~ "fixture-secret-value"
  end

  test "binary artifacts have a JSON-safe representation without changing their bytes", %{
    bridge: bridge
  } do
    assert :ok =
             Bridge.call(
               bridge,
               7,
               "fresh-execution",
               {:artifact, "bytes.bin", "application/octet-stream", <<0, 255>>}
             )

    result = Bridge.finish(bridge, %{status: :ok, display: ""})
    assert [%{encoding: "base64", data: encoded, bytes: 2}] = result.artifacts
    assert Base.decode64!(encoded) == <<0, 255>>
    assert {:ok, _json} = Jason.encode(result)
  end

  test "tool errors are redacted before crossing back into a worker", %{bridge: bridge} do
    assert %{"ok" => false} =
             result =
             Bridge.call(bridge, 7, "fresh-execution", {:tool, "bridge_error", %{}})

    refute Jason.encode!(result) =~ "fixture-secret-value"
  end

  test "queued completion cannot defeat a callback deadline", %{bridge: bridge} do
    task =
      Task.async(fn -> Bridge.call(bridge, 7, "fresh-execution", {:tool, "bridge_wait", %{}}) end)

    assert_receive {:bridge_effect, action}, 2_000
    :ok = :sys.suspend(bridge)

    try do
      send(action, :release)
      Process.sleep(300)
    after
      :ok = :sys.resume(bridge)
    end

    assert_receive {:callback_timeout, 7, "fresh-execution"}, 2_000
    assert %{"ok" => false, "error" => error} = Task.await(task)
    assert error =~ "callback_timeout"

    assert %{effects: :uncertain, status: :timeout} =
             Bridge.finish(bridge, %{status: :ok, display: ""})

    refute_receive {:bridge_effect, _action}
  end

  test "callback deadline kills the actual action and invalidation rejects late calls", %{
    bridge: bridge
  } do
    task =
      Task.async(fn -> Bridge.call(bridge, 7, "fresh-execution", {:tool, "bridge_wait", %{}}) end)

    assert_receive {:bridge_effect, action}, 2_000
    monitor = Process.monitor(action)
    assert_receive {:callback_timeout, 7, "fresh-execution"}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^action, _reason}, 2_000
    assert %{"ok" => false, "error" => error} = Task.await(task)
    assert error =~ "callback_timeout"
    assert :ok = Bridge.invalidate(bridge)

    assert %{"ok" => false} =
             Bridge.call(bridge, 7, "fresh-execution", {:tool, "bridge_wait", %{}})

    refute_receive {:bridge_effect, _action}
  end
end
