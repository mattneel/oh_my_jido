defmodule OhMyJido.NativeV3ExecLifecycleTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  defmodule Append do
    use Jido.Action,
      name: "lifecycle_append",
      schema: Zoi.object(%{value: Zoi.string()})

    @impl true
    def run(%{value: value}, context) do
      File.write!(context.path, value, [:append])
      {:ok, %{bytes: byte_size(value)}}
    end
  end

  defmodule NestedWrite do
    use Jido.Action, name: "lifecycle_nested_write", schema: Zoi.object(%{})

    @impl true
    def run(_params, context) do
      send(context.observer, {:outer_action, self()})

      with {:ok, %{bytes: 4}} <-
             Jido.Exec.run(Append, %{value: "one\n"}, context, lifecycle_observer: nil),
           {:ok, %{bytes: 4}} <-
             Jido.Exec.run(Append, %{value: "two\n"}, context,
               lifecycle_observer: context.escape_observer
             ) do
        {:ok, %{writes: 2}}
      end
    end
  end

  defmodule WaitingWrite do
    use Jido.Action, name: "lifecycle_waiting_write", schema: Zoi.object(%{})

    @impl true
    def run(_params, context) do
      send(context.observer, {:waiting_action, self()})

      receive do
        :publish ->
          File.write!(context.path, "must not publish\n", [:append])
          {:ok, %{written: true}}
      after
        20_000 -> {:error, :test_gate_expired}
      end
    end
  end

  defmodule DetachedWrite do
    use Jido.Action, name: "lifecycle_detached_write", schema: Zoi.object(%{})

    @impl true
    def run(_params, context) do
      child = Jido.Exec.run_async(WaitingWrite, %{}, context, task_supervisor: context.tasks)
      send(context.observer, {:detached_execution, self(), child})

      receive do
        :finish_outer -> {:ok, %{started: true}}
      after
        20_000 -> {:error, :test_gate_expired}
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-native-scope-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{path: Path.join(root, "effect.txt"), tasks: start_supervised!({Task.Supervisor, []})}
  end

  test "nested native Exec cannot disable or replace its owning observer", fixture do
    owner = self()

    escape = %{
      started: fn proof ->
        send(owner, {:escaped_observer, proof})
        {:ok, make_ref()}
      end,
      stopped: fn _token, _proof -> :ok end,
      parent: nil
    }

    context = Map.merge(fixture, %{observer: owner, escape_observer: escape})

    assert {:ok, %{writes: 2}} =
             Jido.Exec.run(NestedWrite, %{}, context,
               task_supervisor: fixture.tasks,
               timeout: 5_000,
               lifecycle_observer: observer(owner)
             )

    assert_receive {:scope_started, root_token, %{parent: nil, owner: ^owner} = root}, 1_000
    assert_receive {:outer_action, action}, 1_000

    assert_receive {:scope_started, first_token, %{parent: ^root_token, owner: ^action} = first},
                   1_000

    assert_closed(first_token, first)

    assert_receive {:scope_started, second_token,
                    %{parent: ^root_token, owner: ^action} = second},
                   1_000

    assert_closed(second_token, second)
    assert_closed(root_token, root)
    assert first.controller != second.controller
    assert first.controller != root.controller
    refute_receive {:escaped_observer, _proof}, 0
    assert File.read!(fixture.path) == "one\ntwo\n"
  end

  test "halted native admission closes its empty group without dispatching an Action", fixture do
    assert {:error, error} =
             Jido.Exec.run(Append, %{value: "must not write\n"}, fixture,
               task_supervisor: fixture.tasks,
               lifecycle_observer: observer(self(), :halt)
             )

    assert_receive {:scope_started, token, proof}, 1_000
    assert_closed(token, proof)
    assert Exception.message(error) =~ "lifecycle observer"
    refute File.exists?(fixture.path)
  end

  test "escaping and invalid native admission failures cannot dispatch or expose callback data",
       fixture do
    secret = "private-lifecycle-admission-value"
    owner = self()

    logs =
      capture_log(fn ->
        for failure <- [:return, :raise, :throw, :exit, :invalid] do
          policy = %{
            started: fn _proof -> fail_admission(failure, secret) end,
            stopped: fn token, proof -> send(owner, {:unexpected_scope_receipt, token, proof}) end,
            parent: nil
          }

          assert {:error, error} =
                   Jido.Exec.run(Append, %{value: "must not write\n"}, fixture,
                     task_supervisor: fixture.tasks,
                     lifecycle_observer: policy
                   )

          refute inspect(error) =~ secret
          refute File.exists?(fixture.path)
          refute_receive {:unexpected_scope_receipt, _token, _proof}, 0
        end
      end)

    refute logs =~ secret
  end

  test "forced control death never manufactures a group closure receipt", fixture do
    execution =
      Jido.Exec.run_async(WaitingWrite, %{}, Map.put(fixture, :observer, self()),
        task_supervisor: fixture.tasks,
        timeout: 5_000,
        lifecycle_observer: observer(self())
      )

    assert_receive {:scope_started, token, %{controller: controller} = proof}, 1_000
    assert controller == execution.pid
    assert_receive {:waiting_action, action}, 1_000
    monitor = Process.monitor(action)
    supervisor_monitor = Process.monitor(proof.supervisor)
    Process.exit(controller, :kill)
    assert {:error, _native_control_failure} = Jido.Exec.await(execution, 5_000)
    assert_receive {:DOWN, ^monitor, :process, ^action, _reason}, 1_000
    refute_receive {:scope_stopped, ^token, _proof}, 0
    assert_receive {:DOWN, ^supervisor_monitor, :process, _supervisor, _reason}, 1_000
    send(action, :publish)
    refute File.exists?(fixture.path)
  end

  test "a parent receipt does not attest separately controlled nested native workers", fixture do
    execution =
      Jido.Exec.run_async(DetachedWrite, %{}, Map.put(fixture, :observer, self()),
        task_supervisor: fixture.tasks,
        timeout: 5_000,
        lifecycle_observer: observer(self())
      )

    assert_receive {:scope_started, root_token, %{parent: nil} = root}, 1_000
    assert_receive {:detached_execution, outer, child}, 1_000
    assert_receive {:scope_started, child_token, %{parent: ^root_token} = child_proof}, 1_000
    assert child.pid == child_proof.controller
    assert child_proof.owner == outer
    assert_receive {:waiting_action, action}, 1_000
    action_monitor = Process.monitor(action)
    assert :erlang.suspend_process(child.pid)

    try do
      send(outer, :finish_outer)
      assert {:ok, %{started: true}} = Jido.Exec.await(execution, 5_000)
      assert_closed(root_token, root)
      assert Process.alive?(action)
      assert Process.alive?(child_proof.supervisor)
      refute_receive {:scope_stopped, ^child_token, _proof}, 0
      refute File.exists?(fixture.path)
    after
      if Process.alive?(child.pid), do: :erlang.resume_process(child.pid)
    end

    assert_closed(child_token, child_proof)
    assert_receive {:DOWN, ^action_monitor, :process, ^action, _reason}, 1_000
    send(action, :publish)
    refute File.exists?(fixture.path)
  end

  defp observer(owner, admission \\ :allow) do
    %{
      started: fn proof ->
        token = make_ref()
        send(owner, {:scope_started, token, proof})

        case admission do
          :allow -> {:ok, token}
          :halt -> {:halt, token, :test_policy_denied}
        end
      end,
      stopped: fn token, proof ->
        send(owner, {:scope_stopped, token, proof})
        :ok
      end,
      parent: nil
    }
  end

  defp assert_closed(token, proof) do
    assert_receive {:scope_stopped, ^token, closed}, 1_000
    assert closed == Map.put(proof, :workers_stopped, true)
    refute Process.alive?(proof.supervisor)
  end

  defp fail_admission(:return, secret), do: {:error, %{opaque: secret}}
  defp fail_admission(:raise, secret), do: raise(ArgumentError, secret)
  defp fail_admission(:throw, secret), do: throw({:opaque, secret})
  defp fail_admission(:exit, secret), do: exit({:opaque, secret})
  defp fail_admission(:invalid, secret), do: %{opaque: secret}
end
