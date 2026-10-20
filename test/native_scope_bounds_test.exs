defmodule OhMyJido.NativeScopeBoundsTest do
  use Jido.AI.TestCase, async: false

  alias OhMyJido.{NativeScopes, Runtime, Session}

  @moduletag timeout: 60_000

  defmodule Probe do
    def fixture(execution_context) do
      {:ok, context} = OhMyJido.Context.fetch(execution_context)
      {_host, opts} = context.host

      %{
        context: context,
        observer: Keyword.fetch!(opts, :observer),
        tasks: Keyword.fetch!(opts, :tasks),
        scope_limit: Keyword.fetch!(opts, :scope_limit)
      }
    end

    def scope do
      %{parent: token} = Jido.Exec.LifecycleObserver.current()
      {token, Jido.Exec.Telemetry.tracker()}
    end

    def root(fixture) do
      {token, controller} = scope()
      send(fixture.observer, {:native_root, self(), token, controller})
    end

    def pause(fixture, kind, value) do
      gate = make_ref()
      monitor = Process.monitor(fixture.observer)
      send(fixture.observer, {kind, self(), gate, value})

      try do
        receive do
          {:continue, ^gate} -> :ok
          {:DOWN, ^monitor, :process, _observer, _reason} -> {:error, :test_owner_stopped}
        after
          20_000 -> {:error, :test_gate_expired}
        end
      after
        Process.demonitor(monitor, [:flush])
      end
    end

    def sequence(iterations, execution_context) do
      fixture = fixture(execution_context)
      checkpoints = [1, div(iterations, 4), iterations]

      Enum.reduce_while(1..iterations, {:ok, %{writes: 0}}, fn index, _acc ->
        case Jido.Exec.run(
               OhMyJido.NativeScopeBoundsTest.Append,
               %{index: index},
               execution_context,
               task_supervisor: fixture.tasks
             ) do
          {:ok, %{index: ^index, scope: token}} ->
            pause_checkpoint(fixture, index, token, checkpoints)

            {:cont, {:ok, %{writes: index}}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
    end

    defp pause_checkpoint(fixture, index, token, checkpoints) do
      if index in checkpoints do
        :ok = pause(fixture, :native_progress, %{index: index, token: token})
      end
    end
  end

  defmodule Append do
    use Jido.Action,
      name: "scope_bounds_append",
      schema: Zoi.object(%{index: Zoi.integer()})

    @impl true
    def run(%{index: index}, execution_context) do
      fixture = Probe.fixture(execution_context)

      with :ok <-
             OhMyJido.Tool.authorize(fixture.context, :edit, %{
               operation: :write,
               path: "writes.txt"
             }) do
        File.write!(Path.join(fixture.context.workspace, "writes.txt"), "#{index}\n", [:append])
        {token, _controller} = Probe.scope()
        {:ok, %{index: index, scope: token}}
      end
    end
  end

  defmodule SequentialWrites do
    use Jido.Action,
      name: "scope_bounds_sequential",
      schema: Zoi.object(%{iterations: Zoi.integer()})

    @impl true
    def run(%{iterations: iterations}, execution_context) do
      Probe.root(Probe.fixture(execution_context))
      Probe.sequence(iterations, execution_context)
    end
  end

  defmodule WaitingWrite do
    use Jido.Action, name: "scope_bounds_waiting", schema: Zoi.object(%{})

    @impl true
    def run(_params, execution_context) do
      fixture = Probe.fixture(execution_context)
      {token, controller} = Probe.scope()
      send(fixture.observer, {:native_waiting, self(), token, controller})

      receive do
        :publish ->
          with :ok <-
                 OhMyJido.Tool.authorize(fixture.context, :edit, %{
                   operation: :write,
                   path: "late.txt"
                 }) do
            File.write!(Path.join(fixture.context.workspace, "late.txt"), "must not write\n")
            {:ok, %{written: true}}
          end
      after
        20_000 -> {:error, :test_gate_expired}
      end
    end
  end

  defmodule DetachedParent do
    use Jido.Action, name: "scope_bounds_detached", schema: Zoi.object(%{})

    @impl true
    def run(_params, execution_context) do
      fixture = Probe.fixture(execution_context)
      {token, controller} = Probe.scope()

      child =
        Jido.Exec.run_async(WaitingWrite, %{}, execution_context, task_supervisor: fixture.tasks)

      send(fixture.observer, {:native_detached, self(), token, controller, child})

      receive do
        :finish_parent -> {:ok, %{started: true}}
      after
        20_000 -> {:error, :test_gate_expired}
      end
    end
  end

  defmodule PinnedWrites do
    use Jido.Action,
      name: "scope_bounds_pinned",
      schema: Zoi.object(%{iterations: Zoi.integer()})

    @impl true
    def run(%{iterations: iterations}, execution_context) do
      fixture = Probe.fixture(execution_context)
      Probe.root(fixture)

      with {:ok, %{started: true}} <-
             Jido.Exec.run(DetachedParent, %{}, execution_context, task_supervisor: fixture.tasks),
           :ok <- Probe.pause(fixture, :native_progress, %{index: 0, token: nil}) do
        Probe.sequence(iterations, execution_context)
      end
    end
  end

  defmodule ForbiddenWrite do
    use Jido.Action, name: "scope_bounds_forbidden", schema: Zoi.object(%{})

    @impl true
    def run(_params, execution_context) do
      fixture = Probe.fixture(execution_context)
      send(fixture.observer, {:forbidden_native_action, self()})
      File.write!(Path.join(fixture.context.workspace, "forbidden.txt"), "must not dispatch\n")
      {:ok, %{written: true}}
    end
  end

  defmodule DeepScope do
    use Jido.Action,
      name: "scope_bounds_deep",
      schema: Zoi.object(%{level: Zoi.integer()})

    @impl true
    def run(%{level: level}, execution_context) do
      fixture = Probe.fixture(execution_context)

      if level < fixture.scope_limit do
        Jido.Exec.run(__MODULE__, %{level: level + 1}, execution_context,
          task_supervisor: fixture.tasks
        )
      else
        {token, _controller} = Probe.scope()
        :ok = Probe.pause(fixture, :native_at_capacity, token)

        result =
          Jido.Exec.run(ForbiddenWrite, %{}, execution_context, task_supervisor: fixture.tasks)

        :ok = Probe.pause(fixture, :native_capacity_result, result)

        case result do
          {:error, _native_admission_error} -> {:ok, %{rejected: true}}
          other -> other
        end
      end
    end
  end

  defmodule DepthLimit do
    use Jido.Action, name: "scope_bounds_limit", schema: Zoi.object(%{})

    @impl true
    def run(_params, execution_context) do
      fixture = Probe.fixture(execution_context)
      Probe.root(fixture)

      Jido.Exec.run(DeepScope, %{level: 2}, execution_context, task_supervisor: fixture.tasks)
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-native-bounds-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, tasks: start_supervised!({Task.Supervisor, []})}
  end

  test "many real nested writes retain only bounded history while their root stays live",
       fixture do
    session = session(fixture, SequentialWrites, 2, 2)
    coordinator = GenServer.whereis(Runtime.via(session))
    iterations = 128
    effect = "bounded-sequential-writes"

    script =
      expect_react do
        user("Write many times under one native scope")
        call("scope_bounds_sequential", %{iterations: 128}, id: "bounded-sequential-writes")
        answer("Every nested write finished once.")
      end

    assert {:ok, run} =
             OhMyJido.prompt(
               session,
               "Write many times under one native scope",
               react_opts(script)
             )

    assert_receive {:native_root, action, root_token, controller}, 5_000

    first =
      Enum.reduce([1, div(iterations, 4), iterations], nil, fn index, first ->
        assert_receive {:native_progress, ^action, gate, %{index: ^index, token: child_token}},
                       5_000

        state = :sys.get_state(coordinator)
        stats = assert_bounds(state, 4, 2)
        assert stats.active == 1
        assert stats.pinned == 0
        assert stats.history == min(index, 2)
        assert stats.total == 1 + min(index, 2)
        assert stats.max_depth == 2

        assert {:ok, %{effect: ^effect, parent: nil, depth: 1, live?: true, origin: origin}} =
                 NativeScopes.fetch(state.native_scope_parents, root_token)

        assert origin.effect == effect
        assert origin.request == run
        assert state.native_scopes[root_token].proof.controller == controller

        assert {:ok,
                %{effect: ^effect, origin: ^origin, parent: ^root_token, depth: 2, live?: false}} =
                 NativeScopes.fetch(state.native_scope_parents, child_token)

        if first do
          assert :error = NativeScopes.fetch(state.native_scope_parents, first)
        end

        assert File.read!(Path.join(fixture.root, "writes.txt")) == writes(index)
        send(action, {:continue, gate})
        first || child_token
      end)

    assert is_reference(first)
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)

    assert {:ok, %{status: :completed, completed_at: _completed_at}} =
             Session.effect_receipt(session, effect)

    final = assert_bounds(:sys.get_state(coordinator), 4, 2)
    assert final.active == 0
    assert final.pinned == 0
    assert File.read!(Path.join(fixture.root, "writes.txt")) == writes(iterations)
    assert :ok = OhMyJido.stop_session(session)
  end

  test "a live detached child pins its closed parent across independent native history churn",
       fixture do
    session = session(fixture, PinnedWrites, 3, 3)
    coordinator = GenServer.whereis(Runtime.via(session))
    coordinator_monitor = Process.monitor(coordinator)
    iterations = 128
    effect = "bounded-pinned-writes"

    script =
      expect_react do
        user("Keep detached native ancestry while churning siblings")
        call("scope_bounds_pinned", %{iterations: 128}, id: "bounded-pinned-writes")
        answer("The detached child shut down without publishing.")
      end

    assert {:ok, run} =
             OhMyJido.prompt(
               session,
               "Keep detached native ancestry while churning siblings",
               react_opts(script)
             )

    assert_receive {:native_root, root_action, root_token, _root_controller}, 5_000

    assert_receive {:native_detached, parent_action, parent_token, parent_controller, child},
                   5_000

    assert_receive {:native_waiting, child_action, child_token, child_controller}, 5_000
    assert child.pid == child_controller
    child_monitor = Process.monitor(child_action)
    controller_monitor = Process.monitor(child_controller)
    state = :sys.get_state(coordinator)
    child_proof = state.native_scopes[child_token].proof
    assert child_proof.owner == parent_action
    assert child_proof.parent == parent_token
    assert child_proof.controller == child_controller
    assert :erlang.suspend_process(child_controller)

    try do
      send(parent_action, :finish_parent)
      assert_receive {:native_progress, ^root_action, initial_gate, %{index: 0}}, 5_000
      state = :sys.get_state(coordinator)
      stats = assert_bounds(state, 6, 3)
      assert stats.active == 2
      assert stats.pinned == 1
      assert stats.history == 0
      assert stats.total == 3
      refute Map.has_key?(state.native_scopes, parent_token)
      refute Process.alive?(parent_controller)

      assert {:ok, %{effect: ^effect, origin: origin, parent: ^root_token, live?: false, pins: 1}} =
               NativeScopes.fetch(state.native_scope_parents, parent_token)

      assert origin.effect == effect
      assert origin.request == run
      send(root_action, {:continue, initial_gate})

      final_gate =
        Enum.reduce([1, div(iterations, 4), iterations], nil, fn index, _gate ->
          assert_receive {:native_progress, ^root_action, gate, %{index: ^index}}, 5_000
          state = :sys.get_state(coordinator)
          stats = assert_bounds(state, 6, 3)
          assert stats.active == 2
          assert stats.pinned == 1
          assert stats.history == min(index, 3)
          assert stats.total == 3 + min(index, 3)
          assert stats.max_depth == 3

          assert {:ok,
                  %{
                    effect: ^effect,
                    origin: ^origin,
                    parent: ^root_token,
                    live?: false,
                    pins: 1,
                    depth: 2
                  }} = NativeScopes.fetch(state.native_scope_parents, parent_token)

          assert {:ok,
                  %{
                    effect: ^effect,
                    origin: ^origin,
                    parent: ^parent_token,
                    live?: true,
                    depth: 3
                  }} = NativeScopes.fetch(state.native_scope_parents, child_token)

          assert state.native_scopes[child_token].proof == child_proof
          assert Process.alive?(child_action)
          assert Process.alive?(child_proof.supervisor)
          refute File.exists?(Path.join(fixture.root, "late.txt"))
          assert File.read!(Path.join(fixture.root, "writes.txt")) == writes(index)
          if index != iterations, do: send(root_action, {:continue, gate})
          gate
        end)

      assert :erlang.resume_process(child_controller)
      assert_receive {:DOWN, ^child_monitor, :process, ^child_action, _reason}, 5_000
      assert_receive {:DOWN, ^controller_monitor, :process, ^child_controller, _reason}, 5_000
      refute Process.alive?(child_proof.supervisor)
      state = :sys.get_state(coordinator)
      refute Map.has_key?(state.native_scopes, child_token)
      settled = assert_bounds(state, 6, 3)
      assert settled.active == 1
      assert settled.pinned == 0
      send(child_action, :publish)
      refute File.exists?(Path.join(fixture.root, "late.txt"))
      send(root_action, {:continue, final_gate})

      assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)

      assert {:ok, %{status: :completed, completed_at: _completed_at}} =
               Session.effect_receipt(session, effect)

      assert File.read!(Path.join(fixture.root, "writes.txt")) == writes(iterations)
      assert :ok = OhMyJido.stop_session(session)
      assert_receive {:DOWN, ^coordinator_monitor, :process, ^coordinator, :shutdown}, 5_000
      send(child_action, :publish)
      refute File.exists?(Path.join(fixture.root, "late.txt"))
    after
      if Process.alive?(child_controller) do
        case Process.info(child_controller, :status) do
          {:status, :suspended} -> :erlang.resume_process(child_controller)
          _running -> :ok
        end
      end
    end
  end

  test "the finite native depth cap rejects a real execution before its user Action dispatch",
       fixture do
    session = session(fixture, DepthLimit, 2, 2)
    coordinator = GenServer.whereis(Runtime.via(session))

    script =
      expect_react do
        user("Reject work beyond the bounded native scope depth")
        call("scope_bounds_limit", %{}, id: "bounded-depth-rejection")
        answer("The extra Action was rejected before dispatch.")
      end

    assert {:ok, run} =
             OhMyJido.prompt(
               session,
               "Reject work beyond the bounded native scope depth",
               react_opts(script)
             )

    assert_receive {:native_root, _root_action, _root_token, _root_controller}, 5_000
    assert_receive {:native_at_capacity, action, gate, token}, 5_000
    state = :sys.get_state(coordinator)
    stats = assert_bounds(state, 4, 2)
    assert stats.total == 4
    assert stats.active == 4
    assert stats.history == 0
    assert stats.max_depth == 4
    assert {:ok, %{depth: 4, live?: true}} = NativeScopes.fetch(state.native_scope_parents, token)
    refute_receive {:forbidden_native_action, _action}, 0
    refute File.exists?(Path.join(fixture.root, "forbidden.txt"))
    send(action, {:continue, gate})

    assert_receive {:native_capacity_result, ^action, result_gate, {:error, _admission_error}},
                   5_000

    assert assert_bounds(:sys.get_state(coordinator), 4, 2) == stats
    refute_receive {:forbidden_native_action, _action}, 0
    refute File.exists?(Path.join(fixture.root, "forbidden.txt"))
    send(action, {:continue, result_gate})
    assert {:ok, %{status: :completed}} = OhMyJido.await(session, run)

    assert {:ok, %{status: :completed, completed_at: _completed_at}} =
             Session.effect_receipt(session, "bounded-depth-rejection")

    final = assert_bounds(:sys.get_state(coordinator), 4, 2)
    assert final.active == 0
    assert final.pinned == 0
    refute_receive {:forbidden_native_action, _action}, 0
    refute File.exists?(Path.join(fixture.root, "forbidden.txt"))
    assert :ok = OhMyJido.stop_session(session)
  end

  defp session(fixture, action, max_resources, max_effects) do
    start_supervised!(
      Supervisor.child_spec(
        {Runtime,
         name: __MODULE__.Host,
         allow_test_scripts: true,
         max_resources: max_resources,
         max_effects: max_effects,
         tools: [action]},
        shutdown: 10_000
      )
    )

    assert {:ok, session} =
             OhMyJido.start_session(__MODULE__.Host,
               workspace: fixture.root,
               permissions: [:custom, :edit],
               host:
                 {OhMyJido.Host.Local,
                  observer: self(), tasks: fixture.tasks, scope_limit: max_resources + max_effects}
             )

    session
  end

  defp assert_bounds(state, total_limit, history_limit) do
    stats = NativeScopes.stats(state.native_scope_parents)
    assert stats.total_limit == total_limit
    assert stats.active_limit == total_limit
    assert stats.depth_limit == total_limit
    assert stats.history_limit == history_limit
    assert stats.total in 0..total_limit
    assert stats.active in 0..stats.active_limit
    assert stats.max_depth in 0..stats.depth_limit
    assert stats.history in 0..history_limit
    assert stats.history_entries == stats.history
    assert stats.total == stats.active + stats.pinned + stats.history
    assert stats.active == map_size(state.native_scopes)
    stats
  end

  defp writes(count), do: Enum.map_join(1..count, "", &"#{&1}\n")
end
