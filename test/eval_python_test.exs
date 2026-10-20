defmodule OhMyJido.EvalPythonTest do
  use Jido.AI.TestCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 2]

  @moduletag :python_eval
  @moduletag skip:
               if(System.get_env("OH_MY_JIDO_PYTHON_EVAL") == "1",
                 do: false,
                 else:
                   "Opt-in: configure Snakepit's Python runtime with grpcio >= 1.84.0, protobuf >= 7.35.1 and its requirements"
               )

  alias OhMyJido.{Context, Eval, Runtime, Session, Tool}

  defmodule Echo do
    use Jido.Action,
      name: "python_eval_echo",
      description: "Returns the actual structured bridge arguments",
      schema: Zoi.object(%{value: Zoi.any()})

    def capability, do: :read

    @impl true
    def run(params, context) do
      with :ok <- Tool.authorize(context, :read), do: {:ok, %{value: params.value}}
    end
  end

  defmodule Block do
    use Jido.Action,
      name: "python_eval_block",
      description: "An observable cancellable host effect",
      schema: Zoi.object(%{})

    def capability, do: :read

    @impl true
    def run(_params, %{oh_my_jido: context} = execution_context) do
      with :ok <- Tool.authorize(execution_context, :read) do
        send(context.metadata.observer, {:python_callback_started, self()})

        receive do
          :release -> {:ok, %{released: true}}
        end
      end
    end
  end

  setup tags do
    # Start the real dependency's runtime pieces without enabling the pool's
    # application bootstrap, which can install/upgrade Python packages.
    assert {:ok, _applications} = Application.ensure_all_started(:grpc_server)
    assert {:ok, _applications} = Application.ensure_all_started(:grpc)

    unless Process.whereis(Snakepit.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: Snakepit.TaskSupervisor})

    for module <- [
          Snakepit.Bridge.SessionStore,
          Snakepit.Bridge.ToolRegistry,
          Snakepit.Pool.Registry,
          Snakepit.Pool.ProcessRegistry,
          Snakepit.ETSOwner,
          Snakepit.GRPC.Listener,
          Snakepit.Pool.Worker.StarterRegistry,
          Snakepit.WorkerProfile.Thread.CapacityStore,
          Snakepit.Pool.WorkerSupervisor,
          Snakepit.Worker.LifecycleManager
        ] do
      unless Process.whereis(module), do: start_supervised!({module, []})
    end

    assert {:ok, _listener} = Snakepit.GRPC.Listener.await_ready()

    root = Path.join(System.tmp_dir!(), "omj-python-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    context = %Context{
      session_id: "python-one",
      workspace: root,
      permissions: MapSet.new([:eval, :read]),
      tools: [Echo, Block],
      metadata: %{observer: self()}
    }

    python_opts = Keyword.merge([isolation: :trusted], Map.get(tags, :python_backend_opts, []))

    eval =
      start_supervised!(
        {Eval,
         backends: %{python: python_opts},
         max_kernels: 3,
         callback_timeout: Map.get(tags, :callback_timeout, 1_000)}
      )

    %{eval: eval, context: context}
  end

  test "two cells persist in one exclusive worker while other sessions remain independent", %{
    eval: eval,
    context: context
  } do
    assert {:ok, %{status: :ok}} = Eval.execute(eval, context, :python, "value = 40")

    assert {:ok, %{status: :ok, display: "42"}} =
             Eval.execute(eval, context, :python, "value + 2")

    other = %{context | session_id: "python-two"}
    assert {:ok, %{status: :error, error: error}} = Eval.execute(eval, other, :python, "value")
    assert error =~ "NameError"
    assert {:ok, first} = Eval.info(eval, context.session_id, :python)
    assert {:ok, second} = Eval.info(eval, other.session_id, :python)
    refute first.worker == second.worker
    assert {:ok, %{display: "42"}} = Eval.execute(eval, context, :python, "value + 2")
  end

  test "successful Python completion receipts release the sole native session resource slot", %{
    eval: eval,
    context: context
  } do
    start_supervised!(
      Supervisor.child_spec(
        {Runtime, name: __MODULE__.NativeHost, tools: [OhMyJido.Tools.Eval], max_resources: 1},
        shutdown: 10_000
      )
    )

    assert {:ok, session} =
             OhMyJido.start_session(__MODULE__.NativeHost,
               workspace: context.workspace,
               permissions: [:eval],
               metadata: %{eval: eval}
             )

    assert {:ok, session_context} = Session.call(session, :context)

    assert {:ok,
            %{
              status: :ok,
              kernel_state: :ready,
              effects: :completed,
              execution_id: first_id
            }} = Eval.execute(eval, session_context, :python, "value = 40")

    assert {:ok, %{worker: worker, controller: controller}} =
             Eval.info(eval, session.id, :python)

    assert {:ok,
            %{
              status: :ok,
              display: "42",
              kernel_state: :ready,
              effects: :completed,
              execution_id: second_id
            }} = Eval.execute(eval, session_context, :python, "value + 2")

    refute first_id == second_id

    assert {:ok, %{status: :ok, display: "43", kernel_state: :ready}} =
             Eval.execute(eval, session_context, :python, "value + 3")

    assert {:ok, %{worker: ^worker, controller: ^controller}} =
             Eval.info(eval, session.id, :python)

    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)
    controller_monitor = Process.monitor(controller)
    assert :ok = OhMyJido.stop_session(session)
    assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 10_000
    assert_receive {:DOWN, ^controller_monitor, :process, ^controller, _reason}, 10_000
    assert {:error, :not_open} = Eval.info(eval, session.id, :python)
  end

  test "public worker RPC cannot forge ownership or an active host-effect nonce", %{
    eval: eval,
    context: context
  } do
    assert {:ok, _} = Eval.execute(eval, context, :python, "value = 40")

    assert {:ok, %{worker: worker, controller: controller}} =
             Eval.info(eval, context.session_id, :python)

    handle = :sys.get_state(controller).handle

    args = %{
      owner: handle.owner,
      generation: handle.generation,
      control_token: "not-the-private-owner-token",
      execution_id: "unregistered",
      session_id: "spoofed-argument-sid",
      source: "value = 99",
      timeout: 1_000,
      callback_timeout: 500,
      output_limit: 256
    }

    assert {:error, _denied} =
             Snakepit.GRPCWorker.execute(worker, "execute", args, 2_000, idempotent: false)

    args = %{
      args
      | control_token: handle.control_token,
        source: "tools.call('python_eval_echo', {'value': 99})"
    }

    assert {:ok, %{"status" => "error", "error" => error}} =
             Snakepit.GRPCWorker.execute(worker, "execute", args, 2_000, idempotent: false)

    assert error =~ "stale_execution"
    assert {:ok, %{status: :ok, display: "40"}} = Eval.execute(eval, context, :python, "value")
  end

  test "bridge preserves nested containers and booleans and enforces denied tools", %{
    eval: eval,
    context: context
  } do
    source =
      "result = tools.call('python_eval_echo', {'value': {'ok': True, 'items': [1, 2], 'absent': None}})\nresult['value']['ok'] and result['value']['items'] == [1, 2] and result['value']['absent'] is None"

    assert {:ok, %{status: :ok, display: "True"}} = Eval.execute(eval, context, :python, source)
    denied = %{context | permissions: MapSet.new([:eval])}

    assert {:ok, %{status: :error, error: error}} =
             Eval.execute(eval, denied, :python, "tools.call('python_eval_echo', {'value': 1})")

    assert error =~ "permission_denied"

    assert {:ok, %{status: :ok, displays: ["shown"], artifacts: [%{data: "42"}]}} =
             Eval.execute(
               eval,
               context,
               :python,
               "display('shown')\nartifact('answer.txt', 'text/plain', '42')\n42"
             )

    assert {:ok, %{status: :ok, artifacts: [%{encoding: "base64", data: encoded}]}} =
             Eval.execute(
               eval,
               context,
               :python,
               "artifact('bytes.bin', 'application/octet-stream', bytes([0, 255]))"
             )

    assert Base.decode64!(encoded) == <<0, 255>>
  end

  test "errors, stderr and combined output quota are bounded", %{eval: eval, context: context} do
    assert {:ok, %{status: :error, error: error}} =
             Eval.execute(eval, context, :python, "raise ValueError('failed cell')")

    assert error =~ "failed cell"

    assert {:ok, %{stderr: "error line\n"}} =
             Eval.execute(
               eval,
               context,
               :python,
               "import sys\nprint('error line', file=sys.stderr)"
             )

    assert {:ok, result} =
             Eval.execute(eval, context, :python, "print('x' * 4096)", output_limit: 128)

    assert result.truncated
    assert byte_size(result.stdout) + byte_size(result.stderr) + byte_size(result.display) <= 128
  end

  test "deadline invalidates affinity and reset starts an explicitly new generation", %{
    eval: eval,
    context: context
  } do
    assert {:ok, _} = Eval.execute(eval, context, :python, "value = 40")
    assert {:ok, before} = Eval.info(eval, context.session_id, :python)

    assert {:ok, %{status: :timeout, effects: :uncertain, kernel_state: :invalidated}} =
             Eval.execute(eval, context, :python, "while True: pass", timeout: 150)

    assert {:error, {:kernel_invalidated, _reason}} =
             Eval.execute(eval, context, :python, "value")

    assert {:ok, after_reset} = Eval.reset(eval, context.session_id, :python)
    assert after_reset.generation > before.generation
    refute after_reset.worker == before.worker
    assert {:ok, %{status: :error}} = Eval.execute(eval, context, :python, "value")
    assert :ok = Eval.close(eval, context.session_id, :python)
    assert {:error, :not_open} = Eval.info(eval, context.session_id, :python)
  end

  test "hard cancellation stops callbacks without automatic effect replay", %{
    eval: eval,
    context: context
  } do
    task =
      Task.async(fn ->
        Eval.execute(eval, context, :python, "tools.call('python_eval_block', {})",
          timeout: 10_000
        )
      end)

    assert_receive {:python_callback_started, worker}, 40_000
    monitor = Process.monitor(worker)
    assert :ok = Eval.interrupt(eval, context.session_id, :python)
    assert {:ok, %{status: :cancelled, kernel_state: :invalidated}} = Task.await(task, 15_000)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
    refute_receive {:python_callback_started, _worker}
    assert {:error, {:kernel_invalidated, _}} = Eval.execute(eval, context, :python, "1")
    assert :ok = Eval.close_session(eval, context.session_id)
  end

  test "controller hard kill revokes the managed worker and callback", %{
    eval: eval,
    context: context
  } do
    assert {:ok, _} = Eval.execute(eval, context, :python, "value = 40")

    assert {:ok, %{worker: worker, controller: controller}} =
             Eval.info(eval, context.session_id, :python)

    worker_ref = Process.monitor(worker)

    task =
      Task.async(fn ->
        Eval.execute(eval, context, :python, "tools.call('python_eval_block', {})",
          timeout: 5_000
        )
      end)

    assert_receive {:python_callback_started, callback}, 5_000
    callback_ref = Process.monitor(callback)
    Process.exit(controller, :kill)
    assert_receive {:DOWN, ^callback_ref, :process, ^callback, _reason}, 15_000
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 15_000
    assert {:error, _reason} = Task.await(task, 15_000)

    assert {:error, {:kernel_invalidated, _reason}} =
             Eval.execute(eval, context, :python, "value")

    assert Process.alive?(eval)
    refute_receive {:python_callback_started, _callback}
  end

  for control <- [:cancel, :coordinator_kill] do
    @control control

    test "native Python control #{@control} revokes the exclusive worker and actual callback", %{
      context: context
    } do
      runtime = OhMyJido.Runtime

      start_supervised!(
        {runtime,
         name: __MODULE__.NativeHost,
         allow_test_scripts: true,
         tools: [OhMyJido.Tools.Eval, Block],
         eval: [backends: %{python: [isolation: :trusted]}, callback_timeout: 20_000],
         metadata: %{observer: self()}}
      )

      {:ok, session} =
        OhMyJido.start_session(__MODULE__.NativeHost,
          workspace: context.workspace,
          permissions: [:eval, :read]
        )

      script =
        expect_react do
          user("Run Python under native cancellation")

          call("eval", %{
            language: "python",
            source: "tools.call('python_eval_block', {})",
            timeout: 25_000
          })

          answer("The Python cell completed.")
        end

      assert {:ok, run} =
               OhMyJido.prompt(
                 session,
                 "Run Python under native cancellation",
                 react_opts(script)
               )

      assert_receive {:python_callback_started, callback}, 40_000
      callback_ref = Process.monitor(callback)
      eval = runtime.eval(__MODULE__.NativeHost)

      assert {:ok, %{worker: worker, controller: controller}} =
               Eval.info(eval, session.id, :python)

      worker_ref = Process.monitor(worker)
      controller_ref = Process.monitor(controller)

      case @control do
        :cancel -> assert :ok = OhMyJido.cancel(session, run)
        :coordinator_kill -> Process.exit(GenServer.whereis(runtime.via(session)), :kill)
      end

      assert_receive {:DOWN, ^callback_ref, :process, ^callback, _reason}, 15_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 15_000

      case @control do
        :cancel ->
          assert {:ok, %{status: :invalidated}} = Eval.info(eval, session.id, :python)
          assert {:error, %{status: :cancelled}} = OhMyJido.await(session, run)

        :coordinator_kill ->
          assert_receive {:DOWN, ^controller_ref, :process, ^controller, _reason}, 15_000
          assert {:error, {:kernel_invalidated, _}} = Eval.info(eval, session.id, :python)
      end

      assert Process.alive?(eval)
      refute_receive {:python_callback_started, _callback}
    end
  end

  @tag callback_timeout: 15_000
  @tag python_backend_opts: [
         adapter_env: [{"OMJ_SYNTHETIC_PRIVATE_ENV", "omj-private-python-environment-71"}]
       ]
  test "a real Python crash keeps native status and logs private without replay or host loss", %{
    eval: eval,
    context: context
  } do
    private_env = "omj-private-python-environment-71"
    source_marker = "omj-private-python-source-before-exit-71"
    effect_path = Path.join(context.workspace, "crash-effect.txt")

    source = """
    # #{source_marker}
    import os
    from oh_my_jido_eval import adapter as eval_adapter
    with open('crash-effect.txt', 'a') as effect:
        effect.write('once\\n')
    tools.call('python_eval_block', {})
    os.write(2, (eval_adapter._CONTROL_TOKEN + '\\n' + os.environ['OMJ_SYNTHETIC_PRIVATE_ENV'] + '\\n#{source_marker}\\n').encode())
    os._exit(71)
    """

    {{control_token, native_status, worker_id, native_session}, logs} =
      with_log([level: :debug, format: "$message $metadata\n", metadata: :all], fn ->
        assert {:ok, _} = Eval.execute(eval, context, :python, "value = 40")

        assert {:ok, %{worker: worker, controller: controller}} =
                 Eval.info(eval, context.session_id, :python)

        handle = :sys.get_state(controller).handle

        config =
          worker
          |> :sys.get_state()
          |> Snakepit.GRPCWorker.PrivateDiagnostics.unwrap_state()
          |> Map.fetch!(:worker_config)

        assert config.private_diagnostics
        assert config.adapter_env["OH_MY_JIDO_EVAL_CONTROL_TOKEN"] == handle.control_token
        assert config.adapter_env["OMJ_SYNTHETIC_PRIVATE_ENV"] == private_env
        assert byte_size(handle.control_token) >= 24
        assert {:ok, native_session} = Snakepit.GRPCWorker.get_session_id(worker)
        assert native_session == handle.session_id

        :sys.replace_state(worker, fn state ->
          Snakepit.Logger.set_process_level(:debug)
          state
        end)

        :ok = :sys.log(worker, true)
        worker_ref = Process.monitor(worker)
        task = Task.async(fn -> Eval.execute(eval, context, :python, source, timeout: 10_000) end)
        assert_receive {:python_callback_started, callback}, 5_000

        queued_args = %{
          owner: handle.owner,
          generation: handle.generation,
          control_token: handle.control_token,
          execution_id: "must-not-replay",
          source: "# #{source_marker}\nopen('crash-effect.txt', 'a').write('replayed\\n')",
          timeout: 1_000,
          callback_timeout: 500,
          output_limit: 256
        }

        queued =
          :gen_server.send_request(
            worker,
            Snakepit.GRPCWorker.PrivateDiagnostics.request(
              worker,
              {:execute, "execute", queued_args, 5_000, [idempotent: false]}
            )
          )

        assert {:ok, starter} =
                 Snakepit.Pool.Worker.StarterRegistry.get_starter_pid(handle.worker_id)

        native_status =
          [worker, starter, Snakepit.Pool.WorkerSupervisor]
          |> Enum.map(&:sys.get_status/1)
          |> inspect(pretty: true, limit: :infinity, printable_limit: :infinity)

        assert native_status =~ handle.worker_id
        assert native_status =~ native_session
        assert native_status =~ "pending_rpc_calls: 1"
        assert native_status =~ "queued_rpc_calls: 1"
        assert native_status =~ "status: :ready"

        # Keep the controller from cleaning up after a transport error before
        # the native worker observes the actual Python port exit.
        :ok = :sys.suspend(controller)

        try do
          send(callback, :release)

          assert_receive {:DOWN, ^worker_ref, :process, ^worker, {:grpc_server_exited, 71}},
                         10_000
        after
          if Process.alive?(controller), do: :sys.resume(controller)
        end

        assert {:ok, %{status: :crashed, kernel_state: :invalidated, effects: :uncertain}} =
                 Task.await(task, 15_000)

        assert {:reply, {:error, _reason}} = :gen_server.wait_response(queued, 5_000)
        assert Process.alive?(eval)
        assert File.read!(effect_path) == "once\n"
        refute_receive {:python_callback_started, _callback}
        assert {:error, {:kernel_invalidated, _}} = Eval.execute(eval, context, :python, "value")
        assert {:ok, _} = Eval.reset(eval, context.session_id, :python)
        assert {:ok, %{status: :error}} = Eval.execute(eval, context, :python, "value")
        assert File.read!(effect_path) == "once\n"
        {handle.control_token, native_status, handle.worker_id, native_session}
      end)

    assert logs =~ "Python gRPC server crashed with status 71"
    assert logs =~ worker_id
    assert logs =~ "Last output: <private output:"
    assert native_status =~ native_session

    for diagnostic <- [logs, native_status],
        private <- [control_token, private_env, source_marker] do
      refute diagnostic =~ private
    end
  end

  test "an unexpected native callback failure cannot append private request arguments", %{
    eval: eval,
    context: context
  } do
    {{control_token, source_marker}, logs} =
      with_log([level: :debug, format: "$message $metadata\n", metadata: :all], fn ->
        assert {:ok, _} = Eval.execute(eval, context, :python, "value = 40")

        assert {:ok, %{worker: worker, controller: controller}} =
                 Eval.info(eval, context.session_id, :python)

        handle = :sys.get_state(controller).handle
        source_marker = "omj-private-malformed-native-callback"
        worker_ref = Process.monitor(worker)

        assert {:error, _reason} =
                 GenServer.call(
                   worker,
                   {:execute, "execute", [handle.control_token, source_marker], 1_000, []}
                 )

        assert_receive {:DOWN, ^worker_ref, :process, ^worker, :private_callback_failed}, 10_000
        assert Process.alive?(eval)

        assert {:error, {:kernel_invalidated, _reason}} =
                 Eval.execute(eval, context, :python, "value")

        {handle.control_token, source_marker}
      end)

    assert logs =~ "Private gRPC worker callback failed"
    refute logs =~ control_token
    refute logs =~ source_marker
  end

  test "real streaming callback exceptions are private before native task forwarding", %{
    eval: eval,
    context: context
  } do
    {{control_token, source_marker}, logs} =
      with_log([level: :debug, format: "$message $metadata\n", metadata: :all], fn ->
        assert {:ok, _} = Eval.execute(eval, context, :python, "value = 40")

        assert {:ok, %{worker: worker, controller: controller}} =
                 Eval.info(eval, context.session_id, :python)

        handle = :sys.get_state(controller).handle
        source_marker = "omj-private-native-stream-source"
        observer = self()

        args = %{
          owner: handle.owner,
          generation: handle.generation,
          control_token: handle.control_token,
          execution_id: "native-stream-without-host-effects",
          source: "# #{source_marker}\nstream_effects = globals().get('stream_effects', 0) + 1",
          timeout: 5_000,
          callback_timeout: 500,
          output_limit: 256
        }

        for kind <- [:error, :throw, :exit] do
          callback = fn payload ->
            send(observer, {:actual_python_stream_chunk, kind, payload})
            private = "#{handle.control_token}:#{source_marker}"

            case kind do
              :error -> raise ArgumentError, private
              :throw -> throw({:private_stream_failure, private})
              :exit -> exit({:private_stream_failure, private})
            end
          end

          assert {:error, reason} =
                   Snakepit.GRPCWorker.execute_stream(
                     worker,
                     "execute",
                     args,
                     callback,
                     5_000,
                     private_diagnostics: false,
                     idempotent: false
                   )

          case kind do
            :error ->
              assert reason == :private_worker_failure

            kind ->
              assert %Snakepit.Error{details: %{kind: ^kind, reason: :private_rpc_failure}} =
                       reason
          end

          assert_receive {:actual_python_stream_chunk, ^kind, %{"is_final" => _}}, 5_000
          assert Process.alive?(worker)
        end

        worker_state =
          worker
          |> :sys.get_state()
          |> Snakepit.GRPCWorker.PrivateDiagnostics.unwrap_state()

        assert worker_state.stats.errors == 3

        assert {:ok, %{status: :ok, display: "3"}} =
                 Eval.execute(eval, context, :python, "stream_effects")

        assert {:ok, %{status: :ok, display: "40"}} =
                 Eval.execute(eval, context, :python, "value")

        {handle.control_token, source_marker}
      end)

    assert logs =~ "Async gRPC request failed with :throw:"
    assert logs =~ "Async gRPC request failed with :exit:"
    refute logs =~ control_token
    refute logs =~ source_marker
  end
end
