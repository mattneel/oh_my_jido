defmodule OhMyJido.SessionRecoveryTest do
  use Jido.AI.TestCase, async: false

  @moduletag timeout: 60_000

  alias OhMyJido.{Eval, Event, Runtime, Tool}

  defmodule ObservedRequests do
    @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

    @impl true
    def transform_request(request, state, config, %{oh_my_jido: context} = runtime_context) do
      with {:ok, projected} <-
             OhMyJido.Models.Transformer.transform_request(
               request,
               state,
               config,
               runtime_context
             ) do
        query =
          request.messages
          |> Enum.reverse()
          |> Enum.find_value(fn
            %{role: :user, content: content} -> Jido.AI.Turn.extract_from_content(content)
            _message -> nil
          end)

        send(
          context.metadata.observer,
          {:model_request, query, request.messages, projected.messages}
        )

        {:ok, projected}
      end
    end
  end

  defmodule WaitingEffect do
    use Jido.Action,
      name: "recovery_wait",
      description: "Wait at an observable authorized effect boundary",
      schema: Zoi.object(%{})

    def capability, do: :read

    @impl true
    def run(_params, %{oh_my_jido: context} = execution_context) do
      with :ok <- Tool.authorize(execution_context, :read) do
        send(context.metadata.observer, {:waiting_effect, self()})

        receive do
          :release -> {:ok, %{released: true}}
        end
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-recovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "a compacted terminal answer reaches the next native model request", %{root: root} do
    session = session(root, context_policy: [max_messages: 4, keep_recent: 4])
    answer_run(session, "Establish the task", "The task is established.")
    answer_run(session, "Inspect the next fact", "The second fact is recorded.")
    answer_run(session, "Finish this turn", "Distinct terminal observation 7319.")

    assert Enum.any?(OhMyJido.events(session), fn
             %Event{kind: :context_compacted, payload: %{removed_messages: count}} -> count > 0
             _event -> false
           end)

    answer_run(session, "Use the previous answer", "The previous answer is available.")
    assert_receive {:model_request, "Use the previous answer", native, projected}
    assert assistant_message?(native, "Distinct terminal observation 7319.")
    assert assistant_message?(projected, "Distinct terminal observation 7319.")

    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    answer_run(session, "Continue after restore", "The restored conversation is available.")
    assert_receive {:model_request, "Continue after restore", native, projected}
    assert assistant_message?(native, "The previous answer is available.")
    assert assistant_message?(projected, "The previous answer is available.")
  end

  for restored? <- [false, true] do
    @restored restored?

    test "a terminal tool exchange survives compaction with restore=#{restored?}", %{root: root} do
      session = session(root, context_policy: [max_messages: 4, keep_recent: 6])
      answer_run(session, "Establish the task", "The task is established.")
      answer_run(session, "Inspect the next fact", "The second fact is recorded.")
      query = "Write one terminal receipt"

      script =
        expect_react do
          user(query)
          call("write", %{path: "receipt.txt", content: "written once", snapshot: "missing"})
          answer("The receipt is complete.")
        end

      assert {:ok, run} =
               OhMyJido.prompt(
                 session,
                 query,
                 Keyword.put(react_opts(script), :max_iterations, 1)
               )

      assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)
      assert File.read!(Path.join(root, "receipt.txt")) == "written once"
      assert Enum.any?(OhMyJido.events(session), &(&1.kind == :context_compacted))

      if @restored do
        assert :ok = OhMyJido.checkpoint(session)
        assert :ok = OhMyJido.stop_session(session)
        assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
      end

      answer_run(session, "Reconcile the terminal receipt", "No effect needs replay.", 1)
      assert_receive {:model_request, "Reconcile the terminal receipt", native, projected}
      assert_receipt_exchange(native)
      assert_receipt_exchange(projected)
      assert File.read!(Path.join(root, "receipt.txt")) == "written once"
      assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
      assert Enum.count(effects, fn {_id, effect} -> effect.name == "write" end) == 1
    end
  end

  test "a hard Eval controller death retains its uncertain resource slot without replay", %{
    root: root
  } do
    session = session(root, max_resources: 1)
    eval = Runtime.eval(__MODULE__.Host)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)

    script =
      expect_react do
        user("Run an owned cell")

        call("eval", %{
          language: "elixir",
          source:
            ~s|Eval.tool("write", %{"path" => "receipt.txt", "content" => "written once", "snapshot" => "missing"}); Eval.tool("recovery_wait", %{})|,
          timeout: 25_000
        })

        answer("Reconcile the interrupted cell without replay.")
      end

    assert {:ok, run} = OhMyJido.prompt(session, "Run an owned cell", react_opts(script))
    assert_receive {:waiting_effect, callback}, 20_000
    callback_monitor = Process.monitor(callback)

    assert {:ok, %{controller: controller, worker: worker}} =
             Eval.info(eval, session.id, :elixir)

    controller_monitor = Process.monitor(controller)
    worker_monitor = Process.monitor(worker)
    Process.exit(controller, :kill)
    assert_receive {:DOWN, ^controller_monitor, :process, ^controller, _reason}, 10_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 10_000
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, _reason}, 10_000
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)
    assert GenServer.whereis(Runtime.via(session)) == coordinator
    assert Process.alive?(eval)

    assert {:ok, %{status: :ready}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", operation: "reset"})

    assert {:error, %{details: %{reason: :resource_capacity}}} =
             OhMyJido.execute_tool(session, "eval", %{
               language: "elixir",
               source:
                 ~s|Eval.tool("write", %{"path" => "unconfirmed-replacement.txt", "content" => "forbidden", "snapshot" => "missing"})|
             })

    refute File.exists?(Path.join(root, "unconfirmed-replacement.txt"))

    assert File.read!(Path.join(root, "receipt.txt")) == "written once"
    refute_receive {:waiting_effect, _callback}

    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert [%{id: callback_effect}] = effects_named(effects, "recovery_wait")

    assert {:error,
            %{
              reason: :cleanup_uncertain,
              cleanup: :uncertain,
              pending_effects: [^callback_effect],
              pending_resources: [:eval],
              native: :confirmed
            }} = OhMyJido.stop_session(session)

    refute_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, _reason}, 0
    assert GenServer.whereis(Runtime.via(session)) == coordinator
    assert {:ok, %{status: :cleanup_uncertain}} = OhMyJido.inspect_session(session)

    assert {:error, :session_stopped} =
             OhMyJido.execute_tool(session, "write", %{
               path: "unconfirmed-replacement.txt",
               content: "forbidden",
               snapshot: "missing"
             })

    refute File.exists?(Path.join(root, "unconfirmed-replacement.txt"))
  end

  test "an enclosing native Action timeout keeps a write uncertain across restore", %{root: root} do
    session = session(root)

    action =
      Task.async(fn ->
        OhMyJido.execute_tool(
          session,
          "shell",
          %{
            executable: "sh",
            args: ["-c", "printf 'written once' >> receipt.txt; sleep 30"],
            timeout_ms: 15_000
          },
          timeout: 2_000
        )
      end)

    wait_until(fn -> File.read(Path.join(root, "receipt.txt")) == {:ok, "written once"} end)
    assert {:error, %Jido.Action.Error.TimeoutError{}} = Task.await(action, 10_000)

    assert {:error, _known_terminal_error} =
             OhMyJido.execute_tool(session, "read", %{path: "missing"})

    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert [%{id: effect_id, status: :uncertain}] = effects_named(effects, "shell")
    assert [%{status: :completed}] = effects_named(effects, "read")

    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    answer_run(session, "Continue without repeating the receipt", "The effect remains uncertain.")
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert [%{id: ^effect_id, status: :uncertain}] = effects_named(effects, "shell")
    assert File.read!(Path.join(root, "receipt.txt")) == "written once"
  end

  test "an existing session uses its replacement runtime Eval for every kernel operation", %{
    root: root
  } do
    session = session(root)
    coordinator = GenServer.whereis(Runtime.via(session))
    eval = Runtime.eval(__MODULE__.Host)

    assert {:ok, %{status: :ok, display: "40"}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", source: "value = 40"})

    assert {:ok, %{worker: worker}} = Eval.info(eval, session.id, :elixir)
    worker_monitor = Process.monitor(worker)
    assert :ok = Supervisor.terminate_child(__MODULE__.Host, :eval)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 10_000
    assert {:ok, replacement} = Supervisor.restart_child(__MODULE__.Host, :eval)
    assert replacement != eval
    assert Runtime.eval(__MODULE__.Host) == replacement
    assert GenServer.whereis(Runtime.via(session)) == coordinator

    assert {:ok, %{status: :ready}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", operation: "open"})

    assert {:ok, %{status: :ok, display: "40"}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", source: "value = 40"})

    assert {:ok, %{status: :ready}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", operation: "reset"})

    assert {:ok, %{status: :ok, display: "42"}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", source: "6 * 7"})

    assert {:ok, %{status: :closed}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", operation: "close"})

    assert {:error, :not_open} = Eval.info(replacement, session.id, :elixir)

    script =
      expect_react do
        user("Use Eval after replacement")
        call("eval", %{language: "elixir", source: "40 + 2"})
        answer("The replacement kernel is usable.")
      end

    assert {:ok, run} = OhMyJido.prompt(session, "Use Eval after replacement", react_opts(script))
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)
    assert {:ok, %{status: :ready}} = Eval.info(replacement, session.id, :elixir)
  end

  test "retention admission failure preserves the coordinator, bindings, subscriber and model slot",
       %{
         root: root
       } do
    session = session(root, max_active: 1, context_policy: [max_retained_bytes: 512])
    coordinator = GenServer.whereis(Runtime.via(session))
    assert :ok = OhMyJido.subscribe(session, self())

    assert {:ok, %{status: :ok, display: "40"}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", source: "retained = 40"})

    admission =
      Task.async(fn ->
        OhMyJido.prompt(session, String.duplicate("mandatory fact ", 100))
      end)

    assert {:error, :retained_context_too_large} = Task.await(admission, 5_000)

    assert GenServer.whereis(Runtime.via(session)) == coordinator
    assert {:ok, %{status: :idle, goal: nil, runs: runs}} = OhMyJido.inspect_session(session)
    assert runs == %{}

    assert {:ok, %{status: :ok, display: "42"}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", source: "retained + 2"})

    answer_run(session, "Continue with a small task", "The admission slot is usable.")
    assert_receive {:oh_my_jido, %Event{kind: :run_started}}
    assert_receive {:oh_my_jido, %Event{kind: :run_completed, payload: %{status: :completed}}}
    assert GenServer.whereis(Runtime.via(session)) == coordinator
  end

  test "explicit host Eval ownership is not replaced with the session runtime service", %{
    root: root
  } do
    external =
      start_supervised!(
        Supervisor.child_spec(
          {Eval, backends: %{elixir: [isolation: :trusted]}},
          id: __MODULE__.ExternalEval,
          shutdown: 10_000
        )
      )

    session = session(root, metadata: %{observer: self(), eval: external})

    assert {:ok, host_context} = OhMyJido.Session.call(session, :context)

    assert {:ok, %{status: :ok, display: "42"}} =
             OhMyJido.execute_tool(session, "eval", %{language: "elixir", source: "40 + 2"})

    assert {:ok, %{status: :ready}} = Eval.info(external, session.id, :elixir)
    assert {:error, :not_open} = Eval.info(Runtime.eval(__MODULE__.Host), session.id, :elixir)

    assert :ok = Supervisor.terminate_child(__MODULE__.Host, :eval)
    assert {:ok, _replacement} = Supervisor.restart_child(__MODULE__.Host, :eval)

    assert {:ok, %{status: :ok, display: "43"}} =
             Tool.execute(host_context, "eval", %{language: "elixir", source: "40 + 3"})
  end

  test "explicit reconciliation retains uncertainty while a restored session runs real new work",
       %{
         root: root
       } do
    File.write!(Path.join(root, "receipt.txt"), "real restored read\n")

    session =
      session(root,
        models: %{roles: %{coding: "anthropic:claude-haiku-4-5"}},
        context_policy: [max_messages: 80, keep_recent: 80, max_bytes: 256_000]
      )

    original =
      expect_react do
        user("Hold one interrupted execution")
        call("read", %{path: "receipt.txt"}, id: "prior-native-read")
        call("recovery_wait", %{}, id: "interrupted-effect")
        answer("This interrupted continuation must not replay")
      end

    assert {:ok, old_run} =
             OhMyJido.prompt(session, "Hold one interrupted execution", react_opts(original))

    assert_receive {:waiting_effect, old_worker}, 10_000
    monitor = Process.monitor(old_worker)
    on_exit(fn -> send(old_worker, :release) end)
    assert {:ok, options} = Runtime.config(__MODULE__.Host)
    options = Keyword.put(options, :name, __MODULE__.Host)
    assert :ok = stop_supervised(__MODULE__.Host)

    # Independently finish any surviving fixture worker before the explicit
    # operator attestation. A dead actor alone is never the cleanup evidence.
    send(old_worker, :release)
    assert_receive {:DOWN, ^monitor, :process, ^old_worker, _reason}, 10_000
    start_supervised!(Supervisor.child_spec({Runtime, options}, shutdown: 10_000))
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    assert {:ok, restored} = OhMyJido.inspect_session(session)
    assert restored.effects["prior-native-read"].status == :completed
    assert restored.runs[old_run].status == :interrupted
    assert restored.effects["interrupted-effect"].status == :uncertain
    refute Map.has_key?(restored.effects["interrupted-effect"], :completed_at)
    refute Map.has_key?(restored.effects["interrupted-effect"], :result)

    for {run_id, ids} <- [
          {old_run <> "-wrong", ["interrupted-effect"]},
          {old_run, []},
          {old_run, ["missing-effect"]},
          {old_run, ["interrupted-effect", "missing-effect"]},
          {old_run, ["interrupted-effect", "prior-native-read"]},
          {old_run, ["interrupted-effect", "interrupted-effect"]}
        ] do
      assert {:error, :reconciliation_mismatch} =
               OhMyJido.reconcile_interrupted(
                 session,
                 run_id,
                 ids,
                 :orphan_resources_reconciled
               )

      assert {:ok, ^restored} = OhMyJido.inspect_session(session)
    end

    assert :ok =
             OhMyJido.reconcile_interrupted(
               session,
               old_run,
               ["interrupted-effect"],
               :orphan_resources_reconciled
             )

    assert {:ok, reconciled} = OhMyJido.inspect_session(session)
    uncertain = reconciled.effects["interrupted-effect"]

    assert %{
             status: :uncertain,
             execution_settlement: %{
               source: :operator,
               execution: :stopped,
               effect: :uncertain,
               native_stop_confirmed: false
             }
           } = uncertain

    refute Map.has_key?(uncertain, :completed_at)
    refute Map.has_key?(uncertain, :result)

    assert {:error, :effect_not_active} =
             OhMyJido.Session.effect_finished(
               session,
               old_run,
               "interrupted-effect",
               {:ok, %{late_result: "must not overwrite the operator boundary"}}
             )

    assert {:error, :reconciliation_mismatch} =
             OhMyJido.reconcile_interrupted(
               session,
               old_run,
               ["interrupted-effect"],
               :orphan_resources_reconciled
             )

    assert {:ok, ^reconciled} = OhMyJido.inspect_session(session)

    continuation =
      expect_react do
        user("Read the real file after reconciliation")
        call("read", %{path: "receipt.txt"}, id: "new-native-read")
        answer("The real file was read without replay")
      end

    continuation = reconciliation_script(continuation, reconciled.conversation)

    assert {:ok, read_run} =
             OhMyJido.prompt(
               session,
               "Read the real file after reconciliation",
               react_opts(continuation)
             )

    assert {:ok, %{status: :completed}} = OhMyJido.await(session, read_run, timeout: 10_000)

    assert_receive {:model_request, "Read the real file after reconciliation", _native, projected}

    assert Enum.any?(projected, fn message ->
             message.role == :tool and message.tool_call_id == "prior-native-read" and
               Jido.AI.Turn.extract_from_content(message.content) =~ "real restored read"
           end)

    refute Enum.any?(projected, fn message ->
             message.role == :tool and message.tool_call_id == "interrupted-effect"
           end)

    assert {:ok, after_read} = OhMyJido.inspect_session(session)
    assert after_read.effects["new-native-read"].status == :completed
    assert elem(after_read.effects["new-native-read"].result, 0) == :ok
    assert elem(after_read.effects["new-native-read"].result, 1).content == "real restored read\n"
    assert after_read.effects["interrupted-effect"] == uncertain
    refute_receive {:waiting_effect, _replayed}, 0

    later =
      expect_react do
        user("Hold later native work")
        call("recovery_wait", %{}, id: "later-effect")
        answer("The later native execution really completed")
      end

    later = reconciliation_script(later, after_read.conversation)

    assert {:ok, later_run} =
             OhMyJido.prompt(session, "Hold later native work", react_opts(later))

    assert_receive {:waiting_effect, later_worker}, 10_000
    on_exit(fn -> send(later_worker, :release) end)
    assert {:ok, live} = OhMyJido.inspect_session(session)

    for {run_id, ids} <- [
          {old_run, ["interrupted-effect"]},
          {later_run, ["later-effect"]}
        ] do
      assert {:error, :execution_not_quiescent} =
               OhMyJido.reconcile_interrupted(
                 session,
                 run_id,
                 ids,
                 :orphan_resources_reconciled
               )
    end

    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert effects == live.effects
    refute Map.has_key?(effects["later-effect"], :execution_settlement)
    send(later_worker, :release)
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, later_run, timeout: 10_000)

    assert {:error, :reconciliation_mismatch} =
             OhMyJido.reconcile_interrupted(
               session,
               later_run,
               ["later-effect"],
               :orphan_resources_reconciled
             )

    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)
    assert {:ok, %{effects: retained}} = OhMyJido.inspect_session(session)
    assert retained["interrupted-effect"] == uncertain
    assert :ok = OhMyJido.stop_session(session)
  end

  test "a malformed restored effect cannot acquire closure through native stop or reconciliation",
       %{root: root} do
    File.write!(Path.join(root, "receipt.txt"), "actual checkpoint read\n")
    session = session(root, models: %{roles: %{coding: "anthropic:claude-haiku-4-5"}})

    script =
      expect_react do
        user("Read before the checkpoint is corrupted")
        call("read", %{path: "receipt.txt"})
        answer("Inspect the actual receipt.")
      end

    assert {:ok, run} = OhMyJido.prompt(session, script.user, react_opts(script))
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)
    assert :ok = OhMyJido.checkpoint(session)
    assert :ok = OhMyJido.stop_session(session)
    assert {:ok, config} = Runtime.config(__MODULE__.Host)
    {adapter, opts} = Jido.Storage.normalize_storage(config[:storage])
    assert {:ok, saved} = adapter.get_checkpoint({__MODULE__.Host, session.id}, opts)
    [{effect_id, effect}] = Map.to_list(saved.effects)
    assert {:ok, %{content: "actual checkpoint read\n"}, _directives} = effect.result
    malformed = Map.drop(effect, [:status, :result, :completed_at])

    corrupted = %{
      saved
      | effects: %{effect_id => malformed},
        runs: Map.update!(saved.runs, run, &Map.put(&1, :status, :running))
    }

    assert :ok = adapter.put_checkpoint({__MODULE__.Host, session.id}, corrupted, opts)
    assert {:ok, ^session} = OhMyJido.resume_session(__MODULE__.Host, session.id)

    assert {:error, :reconciliation_mismatch} =
             OhMyJido.reconcile_interrupted(
               session,
               run,
               [effect_id],
               :orphan_resources_reconciled
             )

    assert {:error, %{reason: :cleanup_uncertain, pending_effects: [^effect_id]}} =
             OhMyJido.stop_session(session)
  end

  defp reconciliation_script(script, conversation) do
    prefix = Enum.flat_map(conversation, &reconciliation_history_turn/1)
    %{script | turns: prefix ++ script.turns}
  end

  defp reconciliation_history_turn(%{role: role, tool_calls: [_ | _] = calls})
       when role in [:assistant, "assistant"] do
    [%{type: :tool_call, tool_calls: Enum.map(calls, &reconciliation_history_call/1)}]
  end

  defp reconciliation_history_turn(_message), do: []

  defp reconciliation_history_call(call) do
    function = reconciliation_field(call, :function, %{}) || %{}

    arguments =
      reconciliation_field(call, :arguments, reconciliation_field(function, :arguments, %{}))

    arguments = if is_binary(arguments), do: Jason.decode!(arguments), else: arguments

    %{
      id: reconciliation_field(call, :id),
      name: reconciliation_field(call, :name, reconciliation_field(function, :name)),
      arguments: arguments
    }
  end

  defp reconciliation_field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp session(root, opts \\ []) do
    runtime_opts =
      Keyword.merge(
        [
          name: __MODULE__.Host,
          allow_test_scripts: true,
          request_transformer: ObservedRequests,
          storage: {Jido.Storage.File, path: Path.join(root, ".store")},
          tools: [
            OhMyJido.Tools.Eval,
            OhMyJido.Tools.Read,
            OhMyJido.Tools.Write,
            OhMyJido.Tools.Shell,
            WaitingEffect
          ],
          eval: [backends: %{elixir: [isolation: :trusted]}, callback_timeout: 20_000],
          tool_timeout_ms: 30_000,
          metadata: %{observer: self()}
        ],
        opts
      )

    start_supervised!(Supervisor.child_spec({Runtime, runtime_opts}, shutdown: 10_000))

    assert {:ok, session} =
             OhMyJido.start_session(__MODULE__.Host,
               workspace: root,
               permissions: [:read, :edit, :exec, :eval]
             )

    session
  end

  defp answer_run(session, query, text, preceding_calls \\ 0) do
    script =
      expect_react do
        user(query)

        if preceding_calls > 0 do
          for _index <- 1..preceding_calls, do: call("read", %{path: "receipt.txt"})
        end

        answer(text)
      end

    assert {:ok, run} = OhMyJido.prompt(session, query, react_opts(script))
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run, timeout: 10_000)
  end

  defp assistant_message?(messages, text) do
    Enum.any?(messages, fn message ->
      message.role == :assistant and Jido.AI.Turn.extract_from_content(message.content) == text
    end)
  end

  defp assert_receipt_exchange(messages) do
    calls =
      Enum.flat_map(messages, fn message ->
        Enum.filter(Map.get(message, :tool_calls) || [], &(Map.get(&1, :name) == "write"))
      end)

    assert [call] = calls

    assert Enum.any?(messages, fn message ->
             message.role == :tool and Map.get(message, :tool_call_id) == call.id and
               Jido.AI.Turn.extract_from_content(message.content) =~ "written"
           end)
  end

  defp effects_named(effects, name),
    do: effects |> Map.values() |> Enum.filter(&(&1.name == name))

  defp wait_until(predicate, attempts \\ 500)

  defp wait_until(_predicate, 0),
    do: flunk("the real effect did not reach its observable boundary")

  defp wait_until(predicate, attempts) do
    if predicate.() do
      :ok
    else
      receive do
      after
        10 -> wait_until(predicate, attempts - 1)
      end
    end
  end
end
