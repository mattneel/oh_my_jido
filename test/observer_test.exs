defmodule OhMyJido.ObserverTest do
  use ExUnit.Case, async: true

  alias OhMyJido.Context
  alias OhMyJido.Intelligence.Observer

  setup do
    context = %Context{
      session_id: "observer-#{System.unique_integer([:positive])}",
      workspace: System.tmp_dir!(),
      permissions: MapSet.new([:observe]),
      adapters: %{observer: {Observer, [target: :local]}}
    }

    %{context: context}
  end

  test "live process metadata omits dictionaries, state and queued messages", %{context: context} do
    parent = self()
    secret = "observer-private-#{System.unique_integer([:positive])}"

    worker =
      start_supervised!(
        {Task,
         fn ->
           Process.put(:private_observer_fixture, secret)
           send(parent, {:worker_ready, self()})

           receive do
             :stop -> :ok
           end
         end}
      )

    assert_receive {:worker_ready, ^worker}, 1_000
    send(worker, {:private_payload, secret})
    pid = worker |> :erlang.pid_to_list() |> List.to_string()

    assert {:ok, %{process: process, atomic: false}} =
             run(context, %{operation: "process", pid: pid})

    assert process.pid == pid
    assert process.message_queue_len == 1
    assert process.memory > 0
    assert %{module: _, function: _, arity: _} = process.initial_call
    refute Map.has_key?(process, :dictionary)
    refute Map.has_key?(process, :messages)
    refute Jason.encode!(process) =~ secret
    assert Process.alive?(worker)
    assert Process.info(worker, :message_queue_len) == {:message_queue_len, 1}
  end

  test "dead and malformed PID selectors are explicit failures", %{context: context} do
    {worker, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    pid = worker |> :erlang.pid_to_list() |> List.to_string()
    assert {:error, :observer_process_gone} = run(context, %{operation: "process", pid: pid})

    assert {:error, :invalid_observer_pid} =
             run(context, %{operation: "process", pid: "System.halt()"})

    assert {:error, :invalid_observer_pid} = run(context, %{operation: "process", pid: "<1.0.0>"})
  end

  test "explicit permission and target are independently required", %{context: context} do
    denied = %{context | permissions: MapSet.new([:read, :eval, :debug])}
    assert {:error, {:permission_denied, :observe}} = run(denied, %{operation: "overview"})
    unbound = %{context | adapters: %{}}
    assert {:error, {:capability_unavailable, :observer}} = run(unbound, %{operation: "overview"})

    assert {:error, {:capability_unavailable, :observer}} =
             Observer.invoke(context, %{operation: :overview}, [])
  end

  test "overview observes real non-resetting VM counters and memory", %{context: context} do
    assert {:ok, %{system: system}} = run(context, %{operation: "overview"})
    assert system.process_limit == :erlang.system_info(:process_limit)
    assert system.wordsize == :erlang.system_info(:wordsize)
    assert system.memory_bytes.total >= system.memory_bytes.processes_used
    assert system.uptime_ms >= 0
    assert system.run_queue >= 0
  end

  test "ETS metadata includes a live private table but never its data", %{context: context} do
    table = :ets.new(:observer_private_example, [:set, :private])
    secret = "table-private-#{System.unique_integer([:positive])}"
    true = :ets.insert(table, {:credential, secret})
    assert {:ok, %{table: entry}} = run(context, %{operation: "table", table: inspect(table)})
    assert entry.protection == "private"
    assert entry.size == 1
    assert is_boolean(entry.read_concurrency)
    refute Jason.encode!(entry) =~ secret
    assert :ets.lookup(table, :credential) == [{:credential, secret}]
    true = :ets.delete(table)

    assert {:error, :observer_table_gone} =
             run(context, %{operation: "table", table: inspect(table)})
  end

  test "supervision traversal is confined to approved roots and bounded", %{context: context} do
    child = %{
      id: :observed_worker,
      start: {Agent, :start_link, [fn -> %{private: "not-observable"} end]}
    }

    supervisor =
      start_supervised!(%{
        id: :observed_root,
        type: :supervisor,
        start: {Supervisor, :start_link, [[child], [strategy: :one_for_one]]}
      })

    context = %{
      context
      | adapters: %{observer: {Observer, [target: :local, supervisors: %{"app" => supervisor}]}}
    }

    assert {:error, :observer_supervisor_not_granted} =
             run(context, %{operation: "supervision", root: "not-granted"})

    assert {:ok, %{entries: [entry], truncated: false}} =
             run(context, %{operation: "supervision", root: "app", limit: 1})

    assert entry.id == "observed_worker"
    assert entry.type == :worker
    [{:observed_worker, worker, :worker, _}] = Supervisor.which_children(supervisor)
    assert Agent.get(worker, & &1) == %{private: "not-observable"}
    refute Jason.encode!(entry) =~ "not-observable"
  end

  test "supervision depth and total-node limits disclose incomplete traversal", %{
    context: context
  } do
    worker = %{id: :leaf, start: {Agent, :start_link, [fn -> :private end]}}

    nested = %{
      id: :nested,
      type: :supervisor,
      start: {Supervisor, :start_link, [[worker], [strategy: :one_for_one]]}
    }

    root =
      start_supervised!(%{
        id: :bounded_root,
        type: :supervisor,
        start: {Supervisor, :start_link, [[nested], [strategy: :one_for_one]]}
      })

    context = %{
      context
      | adapters: %{observer: {Observer, [target: :local, supervisors: %{"app" => root}]}}
    }

    assert {:ok, %{entries: [%{id: "nested"}], truncated: true}} =
             run(context, %{operation: "supervision", root: "app", depth: 1})

    assert {:ok, %{entries: [%{id: "nested"}], truncated: true}} =
             run(context, %{operation: "supervision", root: "app", depth: 2, limit: 1})

    assert {:ok, %{entries: [%{id: "nested"}, %{id: "leaf"}], truncated: false}} =
             run(context, %{operation: "supervision", root: "app", depth: 2, limit: 2})
  end

  test "applications come from the running target, without application environment", %{
    context: context
  } do
    assert {:ok, %{entries: entries}} = run(context, %{operation: "applications", limit: 200})
    elixir = Enum.find(entries, &(&1.name == "elixir"))
    assert elixir.version == to_string(Application.spec(:elixir, :vsn))
    refute Map.has_key?(elixir, :environment)
  end

  test "model cannot choose a target, executor or raw introspection fields", %{context: context} do
    for extra <- [
          %{target: "other@node"},
          %{module: "Code", function: "eval_string"},
          %{fields: ["dictionary"]}
        ] do
      assert {:error, _} = run(context, Map.merge(%{operation: "overview"}, extra))
    end

    assert {:error, _} = run(context, %{operation: "rpc"})
    assert {:error, _} = run(context, %{operation: "processes", limit: 201})
  end

  test "bounded process inventory exposes truncation and output-budget failure", %{
    context: context
  } do
    assert {:ok, %{entries: entries, truncated: true, count: count}} =
             run(context, %{operation: "processes", limit: 2})

    assert count <= 2
    assert Enum.all?(entries, &is_binary(&1.pid))
    context = %{context | limits: %{extension_result_bytes: 32}}

    assert {:error, {:extension_result_limit, :observer, 32}} =
             run(context, %{operation: "overview"})
  end

  test "local collection timeouts return a tagged error without exiting the caller" do
    source_file = Path.expand("../lib/oh_my_jido/intelligence/observer.ex", __DIR__)

    code = """
    Code.require_file(#{inspect(source_file)})
    :ok = :sys.suspend(:application_controller)
    try do
      {:error, :observer_timeout} =
        OhMyJido.Intelligence.Observer.snapshot(%{operation: :applications}, [])
    after
      :ok = :sys.resume(:application_controller)
    end
    """

    ebin = Context |> :code.which() |> to_string() |> Path.dirname()

    {output, status} =
      System.cmd(System.find_executable("elixir"), ["-pa", ebin, "-e", code],
        env: [{"ERL_FLAGS", "+S 2:2 +A 1"}],
        stderr_to_stdout: true
      )

    assert status == 0, output
  end

  defp run(context, params) do
    OhMyJido.Tools.Observer.run(params, %{oh_my_jido: context})
  end
end
