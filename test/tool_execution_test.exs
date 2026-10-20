defmodule OhMyJido.ToolExecutionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Jido.Action.Error
  alias Jido.Exec.PrivateDiagnostics
  alias OhMyJido.{Context, Tool}

  defmodule NativeTool do
    use Jido.Action,
      name: "native_tool_policy_test",
      schema: Zoi.object(%{mode: Zoi.enum(["ok", "retryable", "map_error", "raise", "block"])})

    @impl true
    def run(%{mode: mode}, %{oh_my_jido: context}) do
      send(context.metadata.owner, {:native_attempt, mode, PrivateDiagnostics.active?()})

      case mode do
        "ok" ->
          {:ok, %{content: "typed tool payload", receipt: %{effect: :completed}}}

        "retryable" ->
          {:error,
           Error.execution_error("Effect failed after submission", %{
             reason: :after_effect,
             retry: true
           })}

        "map_error" ->
          {:error,
           %{reason: :effect_outcome_unknown, effect: :uncertain, receipts: [%{id: "one"}]}}

        "raise" ->
          raise ArgumentError, context.metadata.secret

        "block" ->
          send(context.metadata.owner, {:native_worker, self()})
          receive do: (:release -> {:ok, %{status: :released}})
      end
    end
  end

  defmodule StructuredTool do
    use Jido.Action,
      name: "native_structured_tool_policy_test",
      schema:
        Zoi.object(%{
          value: Zoi.any(),
          settings:
            Zoi.object(%{
              count: Zoi.integer(),
              rows: Zoi.list(Zoi.object(%{enabled: Zoi.boolean()}))
            }),
          attributes: Zoi.map()
        })

    @impl true
    def run(params, %{oh_my_jido: context}) do
      send(
        context.metadata.owner,
        {:structured_attempt, params, context.session_id, PrivateDiagnostics.active?()}
      )

      {:ok, params}
    end
  end

  defmodule StopAgent do
    use Jido.Agent, name: "native_stop_tool_test"

    agent do
      schema(
        Zoi.object(%{
          count: Zoi.integer() |> Zoi.default(7),
          retained: Zoi.map() |> Zoi.default(%{domain: "unchanged"})
        })
      )
    end

    routes do
      route("oh_my_jido.stop_child", OhMyJido.Actions.StopChild)
    end
  end

  setup do
    context = %Context{
      session_id: "native-tools-#{System.unique_integer([:positive])}",
      workspace: System.tmp_dir!(),
      permissions: MapSet.new([:custom]),
      tools: [NativeTool],
      metadata: %{
        owner: self(),
        secret: "private-native-tool-#{System.unique_integer([:positive])}"
      }
    }

    %{context: context}
  end

  test "model tool results remain payloads, while routed stop preserves complete domain state" do
    agent = StopAgent.new!(id: "stop-state")

    signal =
      Jido.Signal.new!("oh_my_jido.stop_child", %{tag: "owned-child"}, source: "/tool-test")

    assert {:ok, candidate,
            [%Jido.Agent.Directive.StopChild{tag: "owned-child", reason: :normal}]} =
             Jido.Agent.cmd(agent, signal)

    assert candidate.state == agent.state
    assert candidate.state.count == 7
    assert candidate.state.retained == %{domain: "unchanged"}
  end

  test "the facade keeps typed payloads and private host context out of results", %{
    context: context
  } do
    assert {:ok, result} =
             Tool.execute(context, NativeTool.name(), %{mode: "ok", oh_my_jido: :untrusted})

    assert result == %{content: "typed tool payload", receipt: %{effect: :completed}}
    refute Map.has_key?(result, :agent_state)
    refute Map.has_key?(result, :oh_my_jido)
    assert_receive {:native_attempt, "ok", true}
    refute_receive {:native_attempt, _, _}
  end

  test "wire arguments normalize declared fields while opaque data keeps its original shape", %{
    context: context
  } do
    context = %{context | tools: [StructuredTool]}
    value = %{"ok" => true, "items" => [1, false, nil, %{"value" => "opaque"}]}
    attributes = %{"enabled" => false, "count" => "not a number", "value" => nil}

    params = %{
      "value" => value,
      "settings" => %{"count" => "12", "rows" => [%{"enabled" => false}]},
      "attributes" => attributes
    }

    expected = %{
      value: value,
      settings: %{count: 12, rows: [%{enabled: false}]},
      attributes: attributes
    }

    assert {:ok, ^expected} = Tool.execute(context, StructuredTool.name(), params)
    assert_receive {:structured_attempt, ^expected, session_id, true}
    assert session_id == context.session_id
    refute_receive {:structured_attempt, _, _, _}
  end

  test "wire normalization never accepts a partial numeric value before the native validator", %{
    context: context
  } do
    context = %{context | tools: [StructuredTool]}

    params = %{
      "value" => true,
      "settings" => %{"count" => "12trailing", "rows" => [%{"enabled" => true}]},
      "attributes" => %{}
    }

    assert {:error, %Error.InvalidInputError{}} =
             Tool.execute(context, StructuredTool.name(), params)

    refute_receive {:structured_attempt, _, _, _}
  end

  test "wire aliases cannot override an explicitly supplied declared atom field", %{
    context: context
  } do
    assert {:ok, %{content: "typed tool payload"}} =
             Tool.execute(context, NativeTool.name(), %{"mode" => "raise", mode: "ok"})

    assert_receive {:native_attempt, "ok", true}
    refute_receive {:native_attempt, _, _}
  end

  test "a retryable native failure never repeats an already submitted effect", %{context: context} do
    assert {:error, %Error.ExecutionFailureError{} = error} =
             Tool.execute(context, NativeTool.name(), %{mode: "retryable"})

    assert error.details == %{reason: :after_effect, retry: true}
    assert Error.retryable?(error)
    assert_receive {:native_attempt, "retryable", true}
    refute_receive {:native_attempt, _, _}
  end

  test "the facade preserves the full typed failure receipt instead of nesting it", %{
    context: context
  } do
    assert {:error, %Error.ExecutionFailureError{details: receipt}} =
             Tool.execute(context, NativeTool.name(), %{mode: "map_error"})

    assert receipt == %{
             reason: :effect_outcome_unknown,
             effect: :uncertain,
             receipts: [%{id: "one"}]
           }

    assert_receive {:native_attempt, "map_error", true}
  end

  test "authorization rejects a custom tool before any native action starts", %{context: context} do
    denied = %{context | permissions: MapSet.new()}

    assert {:error, {:permission_denied, :custom}} =
             Tool.execute(denied, NativeTool.name(), %{mode: "ok"})

    refute_receive {:native_attempt, _, _}
  end

  test "native private diagnostics project telemetry without changing the action result", %{
    context: context
  } do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(handler, [:jido, :action, :error], &__MODULE__.capture_error/4, self())

    on_exit(fn -> :telemetry.detach(handler) end)
    policy = %{error: fn _error -> %{type: :private_failure} end, private?: true}

    assert {:error, %Error.ExecutionFailureError{} = error} =
             Jido.Exec.run(NativeTool, %{mode: "raise"}, %{oh_my_jido: context},
               timeout: 5_000,
               private_diagnostics: policy
             )

    assert error.message == context.metadata.secret
    assert error.details.exception == ArgumentError
    assert_receive {:native_attempt, "raise", true}
    assert_receive {:native_error, %{error: %{type: :private_failure}} = metadata}
    refute inspect(metadata) =~ context.metadata.secret
    refute PrivateDiagnostics.active?()

    assert {:error, %Error.ExecutionFailureError{} = ordinary_error} =
             Jido.Exec.run(NativeTool, %{mode: "raise"}, %{oh_my_jido: context}, timeout: 5_000)

    assert ordinary_error.message == context.metadata.secret
    assert_receive {:native_attempt, "raise", false}
    assert_receive {:native_error, %{error: ^ordinary_error}}
  end

  test "native async controller and workers hide private process dictionaries", %{
    context: context
  } do
    policy = %{error: fn _error -> %{type: :private_failure} end, private?: true}

    handle =
      Jido.Exec.run_async(NativeTool, %{mode: "block"}, %{oh_my_jido: context},
        timeout: 5_000,
        private_diagnostics: policy
      )

    assert_receive {:native_attempt, "block", true}
    assert_receive {:native_worker, worker}
    assert Process.info(handle.pid, :dictionary) == {:dictionary, []}
    assert Process.info(worker, :dictionary) == {:dictionary, []}
    send(worker, :release)
    assert {:ok, %{status: :released}} = Jido.Exec.await(handle, 5_000)
    refute PrivateDiagnostics.active?()
  end

  test "escaping private worker failures log no raw reason or captured callback arguments" do
    supervisor = start_supervised!(Task.Supervisor)
    original_trap = Process.flag(:trap_exit, true)
    owner = self()
    secret = "private-escaping-worker-#{System.unique_integer([:positive])}"
    policy = %{error: fn _error -> %{type: :private_failure} end, private?: true}
    call = %{supervisor: supervisor, controller: owner, group_leader: Process.group_leader()}

    try do
      output =
        capture_log(fn ->
          assert {:ok, task} =
                   PrivateDiagnostics.run(policy, fn ->
                     Jido.Exec.Worker.start(call, fn -> raise ArgumentError, secret end)
                   end)

          assert_receive {:DOWN, ref, :process, worker, {:shutdown, :private_execution_failed}},
                         5_000

          assert ref == task.ref
          assert worker == task.pid
          assert_receive {:EXIT, ^worker, {:shutdown, :private_execution_failed}}
        end)

      assert output =~ "Private native execution process failed"
      refute output =~ secret
      refute output =~ "#Function"
      refute PrivateDiagnostics.active?()
    after
      Process.flag(:trap_exit, original_trap)
    end
  end

  test "unsupported retry options and malformed privacy policies cannot start tool work",
       %{context: context} do
    for options <- [
          [max_retries: 0],
          [max_attempts: 1],
          [private_diagnostics: %{error: :not_a_projector, private?: true}]
        ] do
      assert {:error, %Error.InvalidInputError{}} =
               Jido.Exec.run(NativeTool, %{mode: "ok"}, %{oh_my_jido: context}, options)
    end

    refute_receive {:native_attempt, _, _}
  end

  def capture_error(_event, _measurements, %{name: "native_tool_policy_test"} = metadata, owner),
    do: send(owner, {:native_error, metadata})

  def capture_error(_event, _measurements, _metadata, _owner), do: :ok
end
