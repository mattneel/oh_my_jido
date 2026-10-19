defmodule OhMyJido.EvalBackendsTest do
  use ExUnit.Case, async: false

  alias OhMyJido.{Context, Eval, Tool}

  defmodule Echo do
    use Jido.Action,
      name: "eval_echo",
      description: "Returns structured arguments at the authorized test boundary",
      schema: Zoi.object(%{value: Zoi.any()})

    def capability, do: :read

    @impl true
    def run(params, context) do
      with :ok <- Tool.authorize(context, :read, %{operation: :eval_echo}) do
        {:ok, %{value: params.value}}
      end
    end
  end

  defmodule Block do
    use Jido.Action,
      name: "eval_block",
      description: "Waits at an observable effect boundary",
      schema: Zoi.object(%{})

    def capability, do: :read

    @impl true
    def run(_params, %{oh_my_jido: context} = execution_context) do
      with :ok <- Tool.authorize(execution_context, :read) do
        send(context.metadata.observer, {:bridge_started, self()})

        receive do
          :release -> {:ok, %{released: true}}
        end
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %Context{
      session_id: "session-one",
      workspace: root,
      permissions: MapSet.new([:eval, :read]),
      tools: [Echo, Block],
      metadata: %{observer: self()}
    }

    eval =
      start_supervised!(
        {Eval,
         backends: %{elixir: [isolation: :trusted], javascript: [isolation: :trusted]},
         max_kernels: 4,
         idle_timeout: 60_000,
         callback_timeout: 10_000}
      )

    %{eval: eval, context: context}
  end

  for {language, first, second, missing, failure, output, waiting, bridge, denied, display} <- [
        {:elixir, "alias String, as: Text; value = 40", "value + Text.length(\"ok\")", "value",
         "raise \"cell failed\"", "IO.write(String.duplicate(\"x\", 4096))",
         "receive do :never -> :ok end",
         "Eval.tool(\"eval_echo\", %{\"value\" => %{\"ok\" => true, \"items\" => [1, 2]}})",
         "Eval.tool(\"eval_echo\", %{\"value\" => 1})",
         "Eval.display(\"shown\"); Eval.artifact(\"answer.txt\", \"text/plain\", \"42\"); 42"},
        {:javascript, "var value = 40", "value + 2", "value", "throw new Error('cell failed')",
         "console.log('x'.repeat(4096))", "while (true) {}",
         "tools.call('eval_echo', {value: {ok: true, items: [1, 2]}})",
         "tools.call('eval_echo', {value: 1})",
         "display('shown'); artifact('answer.txt', 'text/plain', '42'); 42"}
      ] do
    @language language
    @first first
    @second second
    @missing missing
    @failure failure
    @output output
    @waiting waiting
    @bridge bridge
    @denied denied
    @display display

    test "#{language}: two cells retain state and independent sessions do not share it", %{
      eval: eval,
      context: context
    } do
      assert {:ok, %{status: :ok}} = Eval.execute(eval, context, @language, @first)

      assert {:ok, %{status: :ok, display: "42"}} =
               Eval.execute(eval, context, @language, @second)

      other = %{context | session_id: "session-two"}
      assert {:ok, %{status: :error}} = Eval.execute(eval, other, @language, @missing)

      assert {:ok, %{status: :ok, display: "42"}} =
               Eval.execute(eval, context, @language, @second)
    end

    test "#{language}: structured authorized tools, denied calls, displays and artifacts", %{
      eval: eval,
      context: context
    } do
      assert {:ok, %{status: :ok, display: value}} =
               Eval.execute(eval, context, @language, @bridge)

      assert value =~ "true"
      denied = %{context | permissions: MapSet.new([:eval])}

      assert {:ok, %{status: :error, error: error}} =
               Eval.execute(eval, denied, @language, @denied)

      assert inspect(error) =~ "permission_denied"

      assert {:ok, %{status: :ok, displays: ["shown"], artifacts: [artifact]}} =
               Eval.execute(eval, context, @language, @display)

      assert artifact.name == "answer.txt"
      assert artifact.data == "42"
    end

    test "#{language}: errors and combined output quota are explicit", %{
      eval: eval,
      context: context
    } do
      assert {:ok, %{status: :error, error: error}} =
               Eval.execute(eval, context, @language, @failure)

      assert inspect(error) =~ "cell failed"
      assert {:ok, result} = Eval.execute(eval, context, @language, @output, output_limit: 128)
      assert result.truncated

      assert byte_size(result.stdout) + byte_size(result.stderr) + byte_size(result.display) <=
               128
    end

    test "#{language}: timeout invalidates state until explicit reset", %{
      eval: eval,
      context: context
    } do
      assert {:ok, _} = Eval.execute(eval, context, @language, @first)

      assert {:ok, %{status: :timeout, kernel_state: :invalidated, effects: :uncertain}} =
               Eval.execute(eval, context, @language, @waiting, timeout: 150)

      assert {:error, {:kernel_invalidated, _}} = Eval.execute(eval, context, @language, @second)
      assert {:ok, _} = Eval.reset(eval, context.session_id, @language)
      assert {:ok, %{status: :error}} = Eval.execute(eval, context, @language, @missing)
      assert :ok = Eval.close(eval, context.session_id, @language)
      assert {:error, :not_open} = Eval.info(eval, context.session_id, @language)
    end

    test "#{language}: interrupt kills active callbacks without replay and rejects late results",
         %{eval: eval, context: context} do
      source =
        if @language == :elixir,
          do: "Eval.tool(\"eval_block\", %{})",
          else: "tools.call('eval_block', {})"

      task = Task.async(fn -> Eval.execute(eval, context, @language, source, timeout: 5_000) end)
      assert_receive {:bridge_started, worker}, 10_000
      monitor = Process.monitor(worker)

      assert {:error, :stale_execution} =
               Eval.interrupt(eval, context.session_id, @language, "old-execution")

      assert Process.alive?(worker)
      assert :ok = Eval.interrupt(eval, context.session_id, @language)
      assert {:ok, %{status: :cancelled, kernel_state: :invalidated}} = Task.await(task, 10_000)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
      refute_receive {:bridge_started, _worker}
      assert {:error, {:kernel_invalidated, _}} = Eval.execute(eval, context, @language, @second)
    end

    test "#{language}: controller hard kill closes the ERTS and active callback", %{
      eval: eval,
      context: context
    } do
      assert {:ok, _} = Eval.execute(eval, context, @language, @first)

      assert {:ok, %{worker: worker, controller: controller}} =
               Eval.info(eval, context.session_id, @language)

      worker_ref = Process.monitor(worker)

      source =
        if @language == :elixir,
          do: "Eval.tool(\"eval_block\", %{})",
          else: "tools.call('eval_block', {})"

      task = Task.async(fn -> Eval.execute(eval, context, @language, source, timeout: 5_000) end)
      assert_receive {:bridge_started, callback}, 5_000
      callback_ref = Process.monitor(callback)
      Process.exit(controller, :kill)
      assert_receive {:DOWN, ^callback_ref, :process, ^callback, _reason}, 5_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 5_000
      assert {:error, _reason} = Task.await(task, 10_000)

      assert {:error, {:kernel_invalidated, _reason}} =
               Eval.execute(eval, context, @language, @second)

      assert Process.alive?(eval)
      refute_receive {:bridge_started, _callback}
    end

    test "#{language}: native bootstrap IO stays data-only and is delivered exactly once", %{
      context: context
    } do
      launcher = Path.join(context.workspace, "native-boot")

      File.write!(launcher, ~S"""
      #!/bin/sh
      exec "$@" -eval 'ok = io:setopts(user, [{encoding, unicode}]), ok = io:setopts(standard_error, [{encoding, unicode}]), ok = io:put_chars(user, <<"native-boot-stdout\n">>), ok = io:put_chars(standard_error, <<"native-boot-stderr\n">>), ok = file:write_file("native-boot-ready", <<"ready">>).'
      """)

      File.chmod!(launcher, 0o700)

      eval =
        start_supervised!(
          {Eval, backends: %{@language => [isolation: :trusted, launcher: {launcher, []}]}},
          id: :native_boot_eval
        )

      assert {:ok, _kernel} = Eval.open(eval, context, @language)
      wait_for_marker(Path.join(context.workspace, "native-boot-ready"), 200)

      assert {:ok, %{status: :ok, stdout: stdout, stderr: stderr}} =
               Eval.execute(eval, context, @language, @first)

      assert stdout == "native-boot-stdout\n"
      assert stderr == "native-boot-stderr\n"

      assert {:ok, %{status: :ok, display: "42", stdout: "", stderr: ""}} =
               Eval.execute(eval, context, @language, @second)

      assert {:ok, %{status: :ok, display: value}} =
               Eval.execute(eval, context, @language, @bridge)

      assert value =~ "true"
    end

    test "#{language}: ERTS owner crash leaves host alive and never silently opens a fresh kernel",
         %{
           eval: eval,
           context: context
         } do
      assert {:ok, _} = Eval.execute(eval, context, @language, @first)
      assert {:ok, %{worker: worker}} = Eval.info(eval, context.session_id, @language)
      monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
      assert Process.alive?(eval)
      assert {:error, {:kernel_invalidated, _}} = Eval.execute(eval, context, @language, @second)
      assert {:ok, _} = Eval.reset(eval, context.session_id, @language)
      assert {:ok, %{status: :error}} = Eval.execute(eval, context, @language, @missing)
    end
  end

  test "JavaScript denies every default Beam handler and hides native authority", %{
    eval: eval,
    context: context
  } do
    source = "typeof Beam + ':' + typeof process + ':' + typeof fetch"

    assert {:ok, %{status: :ok, display: "undefined:undefined:undefined"}} =
             Eval.execute(eval, context, :javascript, source)

    assert {:ok, %{status: :error}} =
             Eval.execute(
               eval,
               context,
               :javascript,
               "Beam.call('__beam_rpc', 'host', 'erlang', 'halt', [])"
             )
  end

  test "Elixir diagnostics and host process isolation are real", %{eval: eval, context: context} do
    assert {:ok, %{status: :ok, diagnostics: diagnostics}} =
             Eval.execute(eval, context, :elixir, "fn unused -> :ok end; :ok")

    assert Enum.any?(diagnostics, &(&1.severity == :warning))
    assert {:ok, %{display: remote_pid}} = Eval.execute(eval, context, :elixir, "System.pid()")
    refute remote_pid == inspect(System.pid())

    assert {:ok, %{status: :ok}} =
             Eval.execute(
               eval,
               context,
               :elixir,
               "System.put_env(\"OMJ_EVAL_PEER_ONLY\", \"yes\"); :ok"
             )

    assert System.get_env("OMJ_EVAL_PEER_ONLY") == nil
  end

  test "isolated ERTS never forwards worker-controlled BEAM destinations into the host", %{
    eval: eval,
    context: context
  } do
    Process.register(self(), __MODULE__.Sentinel)

    source =
      "send(Process.whereis(:user), {:message, #{inspect(__MODULE__.Sentinel)}, :escaped_eval_message}); :ok"

    assert {:ok, %{status: :ok}} = Eval.execute(eval, context, :elixir, source)
    refute_receive :escaped_eval_message
    assert Process.alive?(eval)
  end

  test "unknown remote bridge operations cannot request arbitrary host MFA", %{
    eval: eval,
    context: context
  } do
    source = """
    %{request: request} = :sys.get_state(Process.group_leader())
    :io.request(:user, {:omj_eval, request.generation, request.id, {:rpc, "erlang", "halt", []}})
    """

    assert {:ok, %{status: :ok, display: display}} = Eval.execute(eval, context, :elixir, source)
    assert display =~ "unknown_bridge_operation"
    assert Process.alive?(eval)
  end

  test "cell labels never reuse the execution authority token", %{eval: eval, context: context} do
    assert {:ok, first} = Eval.execute(eval, context, :elixir, "1", cell_id: "same-label")
    assert {:ok, second} = Eval.execute(eval, context, :elixir, "2", cell_id: "same-label")
    refute first.execution_id == second.execution_id
  end

  test "an Eval manager restart requires explicit reset instead of silently dropping bindings", %{
    eval: eval,
    context: context
  } do
    assert {:ok, _} = Eval.execute(eval, context, :elixir, "retained = 42")
    manager = Eval.child(eval, :manager)
    monitor = Process.monitor(manager)
    Process.exit(manager, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^manager, _reason}, 5_000
    # Supervisor calls wait for the one-for-all restart transaction to finish.
    refute Eval.child(eval, :manager) == manager

    assert {:error, {:kernel_invalidated, :eval_supervisor_restarted}} =
             Eval.execute(eval, context, :elixir, "retained")

    assert {:ok, _} = Eval.reset(eval, context, :elixir)
    assert {:ok, %{status: :error}} = Eval.execute(eval, context, :elixir, "retained")
  end

  test "cell-requested ERTS termination cannot terminate the host", %{
    eval: eval,
    context: context
  } do
    assert {:ok, %{status: :crashed, kernel_state: :invalidated, effects: :uncertain}} =
             Eval.execute(eval, context, :elixir, "System.halt(79)")

    assert Process.alive?(eval)
    assert {:error, {:kernel_invalidated, _}} = Eval.execute(eval, context, :elixir, "1")
  end

  test "hard interrupt kills the real ERTS even when guest stdio cannot handle EOF", %{
    eval: eval,
    context: context
  } do
    assert {:ok, _} = Eval.execute(eval, context, :elixir, "retained = 42")
    assert {:ok, %{worker: worker}} = Eval.info(eval, context.session_id, :elixir)
    %{os_pid: pid, os_identity: identity} = OhMyJido.Eval.PortOwner.identity(worker)
    marker = Path.join(context.workspace, "stdio-suspended")

    task =
      Task.async(fn ->
        Eval.execute(
          eval,
          context,
          :elixir,
          ":sys.suspend(:user); File.write!(\"stdio-suspended\", \"ready\"); Process.sleep(:infinity)",
          timeout: 5_000
        )
      end)

    wait_for_marker(marker, 200)
    assert :ok = Eval.interrupt(eval, context.session_id, :elixir)

    assert {:ok, %{status: :cancelled, cleanup: :confirmed, kernel_state: :invalidated}} =
             Task.await(task, 10_000)

    case OhMyJido.Process.capture_identity(pid) do
      {:error, _gone} -> :ok
      {:ok, current} -> assert current.start != identity.start or current.state == "Z"
    end

    assert Process.alive?(eval)
    assert {:error, {:kernel_invalidated, _}} = Eval.execute(eval, context, :elixir, "retained")
  end

  test "guest-crafted JSON is complexity bounded before host decoding", %{
    eval: eval,
    context: context
  } do
    source = """
    %{request: request} = :sys.get_state(Process.group_leader())
    %{port: wire} = :sys.get_state(Process.whereis(:user))
    nested = Enum.reduce(1..80, %{}, fn _, value -> %{"nested" => value} end)
    frame = %{type: "callback", generation: request.generation, execution_id: request.id,
      id: 1, operation: "tool", arguments: ["eval_echo", nested]}
    Port.command(wire, [Jason.encode!(frame), "\\n"])
    Process.sleep(:infinity)
    """

    assert {:ok, %{status: :crashed, kernel_state: :invalidated, effects: :uncertain}} =
             Eval.execute(eval, context, :elixir, source, timeout: 5_000)

    assert Process.alive?(eval)
  end

  test "disabled backends and missing OS isolation fail without fallback", %{context: context} do
    disabled = start_supervised!({Eval, backends: %{}}, id: :disabled_eval)

    assert {:error, {:backend_unavailable, :python}} =
             Eval.execute(disabled, context, :python, "1")

    guarded = start_supervised!({Eval, backends: %{elixir: []}}, id: :guarded_eval)
    assert {:error, {:isolation_required, :elixir}} = Eval.execute(guarded, context, :elixir, "1")
  end

  test "admission, idle invalidation and explicit session cleanup", %{context: context} do
    eval =
      start_supervised!(
        {Eval,
         backends: %{elixir: [isolation: :trusted]},
         max_kernels: 1,
         idle_timeout: 250,
         sweep_interval: 25},
        id: :limited_eval
      )

    assert {:ok, _} = Eval.open(eval, context, :elixir)
    assert {:error, :kernel_limit} = Eval.open(eval, %{context | session_id: "another"}, :elixir)
    assert {:ok, %{controller: controller}} = Eval.info(eval, context.session_id, :elixir)
    monitor = Process.monitor(controller)
    assert_receive {:DOWN, ^monitor, :process, ^controller, _reason}, 10_000

    assert {:error, {:kernel_invalidated, :idle_expired}} =
             Eval.execute(eval, context, :elixir, "1")

    assert :ok = Eval.close_session(eval, context.session_id)
  end

  defp wait_for_marker(_path, 0), do: flunk("isolated ERTS did not write the readiness marker")

  defp wait_for_marker(path, remaining) do
    unless File.exists?(path) do
      Process.sleep(10)
      wait_for_marker(path, remaining - 1)
    end
  end
end
