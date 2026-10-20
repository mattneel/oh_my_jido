defmodule OhMyJido.EvalNativeControlTest do
  use Jido.AI.TestCase, async: false

  alias OhMyJido.{Eval, Runtime, Session, Tool}

  defmodule WaitingTool do
    use Jido.Action,
      name: "eval_native_wait",
      description: "An observable host callback controlled by the native run",
      schema: Zoi.object(%{})

    def capability, do: :read

    @impl true
    def run(_params, %{oh_my_jido: context} = execution_context) do
      with :ok <- Tool.authorize(execution_context, :read) do
        send(context.metadata.observer, {:native_eval_callback, self()})

        receive do
          :release -> {:ok, %{released: true}}
        end
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-native-eval-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!(
      {Runtime,
       name: __MODULE__.Host,
       allow_test_scripts: true,
       tools: [OhMyJido.Tools.Eval, OhMyJido.Tools.Write, WaitingTool],
       max_resources: 1,
       eval: [
         backends: %{elixir: [isolation: :trusted], javascript: [isolation: :trusted]},
         callback_timeout: 20_000
       ],
       metadata: %{observer: self()}}
    )

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Host, workspace: root, permissions: [:eval, :read, :edit])

    %{session: session, eval: Runtime.eval(__MODULE__.Host)}
  end

  for {language, source} <- [
        {:elixir, "Eval.tool(\"eval_native_wait\", %{})"},
        {:javascript, "tools.call('eval_native_wait', {})"}
      ] do
    @language language
    @source source

    test "#{language}: matched successful cells release the sole native session resource slot", %{
      session: session,
      eval: eval
    } do
      assert {:ok, context} = Session.call(session, :context)

      first_source =
        if @language == :elixir, do: "value = 40", else: "var value = 40; value"

      assert {:ok,
              %{
                status: :ok,
                kernel_state: :ready,
                effects: :completed,
                execution_id: first_id
              }} = Eval.execute(eval, context, @language, first_source)

      assert {:ok, %{worker: worker, controller: controller}} =
               Eval.info(eval, session.id, @language)

      assert {:ok,
              %{
                status: :ok,
                display: "42",
                kernel_state: :ready,
                effects: :completed,
                execution_id: second_id
              }} = Eval.execute(eval, context, @language, "value + 2")

      refute first_id == second_id

      assert {:ok, %{status: :ok, display: "43", kernel_state: :ready}} =
               Eval.execute(eval, context, @language, "value + 3")

      assert {:ok, %{worker: ^worker, controller: ^controller}} =
               Eval.info(eval, session.id, @language)

      coordinator = GenServer.whereis(Runtime.via(session))
      coordinator_monitor = Process.monitor(coordinator)
      worker_monitor = Process.monitor(worker)
      controller_monitor = Process.monitor(controller)
      assert :ok = OhMyJido.stop_session(session)
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 10_000
      assert_receive {:DOWN, ^controller_monitor, :process, ^controller, _reason}, 10_000
      assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 10_000
    end

    test "#{language}: native run cancellation reaches the actual isolated kernel and callback",
         %{session: session, eval: eval} do
      script =
        expect_react do
          user("Run a cancellable Eval cell")
          call("eval", %{language: Atom.to_string(@language), source: @source, timeout: 25_000})
          answer("The Eval cell finished.")
        end

      assert {:ok, run} =
               OhMyJido.prompt(session, "Run a cancellable Eval cell", react_opts(script))

      assert_receive {:native_eval_callback, callback}, 20_000
      callback_ref = Process.monitor(callback)
      assert {:ok, %{worker: worker}} = Eval.info(eval, session.id, @language)
      worker_ref = Process.monitor(worker)
      assert :ok = OhMyJido.cancel(session, run)
      assert_receive {:DOWN, ^callback_ref, :process, ^callback, _reason}, 10_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 10_000
      assert {:ok, %{status: :invalidated}} = Eval.info(eval, session.id, @language)
      assert {:error, %{status: :cancelled}} = OhMyJido.await(session, run)
      refute_receive {:native_eval_callback, _callback}
      assert Process.alive?(eval)
    end

    test "#{language}: a timed-out cell retains its applied write and uncertain journal outcome",
         %{
           session: session
         } do
      source =
        case @language do
          :elixir ->
            ~s|Eval.tool("write", %{"path" => "receipt.txt", "content" => "applied", "snapshot" => "missing"}); receive do :never -> :ok end|

          :javascript ->
            "tools.call('write', {path: 'receipt.txt', content: 'applied', snapshot: 'missing'}); while (true) {}"
        end

      script =
        expect_react do
          user("Record an uncertain Eval effect")
          call("eval", %{language: Atom.to_string(@language), source: source, timeout: 1_000})
          answer("The uncertain write requires reconciliation, not replay.")
        end

      {:ok, run} = OhMyJido.prompt(session, "Record an uncertain Eval effect", react_opts(script))
      assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)
      assert {:ok, %{workspace: root, effects: effects}} = OhMyJido.inspect_session(session)
      assert File.read!(Path.join(root, "receipt.txt")) == "applied"
      assert Enum.any?(Map.values(effects), &(&1.name == "eval" and &1.status == :uncertain))
      assert Enum.any?(Map.values(effects), &(&1.name == "write" and &1.status == :completed))
    end

    test "#{language}: coordinator kill bypasses terminate but still revokes callbacks and closes ERTS workers",
         %{session: session, eval: eval} do
      script =
        expect_react do
          user("Run an owned Eval cell")
          call("eval", %{language: Atom.to_string(@language), source: @source, timeout: 25_000})
          answer("The Eval cell finished.")
        end

      assert {:ok, _run} = OhMyJido.prompt(session, "Run an owned Eval cell", react_opts(script))
      assert_receive {:native_eval_callback, callback}, 20_000
      callback_ref = Process.monitor(callback)

      assert {:ok, %{worker: worker, controller: controller}} =
               Eval.info(eval, session.id, @language)

      worker_ref = Process.monitor(worker)
      controller_ref = Process.monitor(controller)
      coordinator = GenServer.whereis(Runtime.via(session))
      Process.exit(coordinator, :kill)
      assert_receive {:DOWN, ^callback_ref, :process, ^callback, _reason}, 10_000
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, _reason}, 10_000
      assert_receive {:DOWN, ^controller_ref, :process, ^controller, _reason}, 10_000
      assert {:error, {:kernel_invalidated, _reason}} = Eval.info(eval, session.id, @language)
      assert Process.alive?(eval)
      refute_receive {:native_eval_callback, _callback}
    end
  end
end
