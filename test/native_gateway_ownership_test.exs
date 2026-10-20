defmodule OhMyJido.NativeGatewayOwnershipTest do
  use Jido.AI.TestCase, async: false

  alias Jido.AgentServer
  alias OhMyJido.Runtime

  setup do
    root =
      Path.join(System.tmp_dir!(), "omj-native-gateway-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!(
      Supervisor.child_spec(
        {Finch,
         name: __MODULE__.Finch, pools: %{default: [protocols: [:http1], size: 1, count: 1]}},
        id: __MODULE__.Finch
      )
    )

    start_supervised!(
      {Runtime,
       name: __MODULE__.Host,
       allow_test_scripts: true,
       model_roles: %{coding: "anthropic:claude-sonnet-4-6"}}
    )

    %{root: root}
  end

  test "native scripted requests retain host Finch ownership across empty and tool-bearing sessions",
       %{
         root: root
       } do
    shared_pools = pool_pids(ReqLLM.Finch)

    {:ok, empty} =
      OhMyJido.start_session(__MODULE__.Host, workspace: root, tools: [], permissions: [])

    assert_native_descriptors(empty)

    empty_script =
      expect_react do
        user("Initialize the host-owned native model gateway without tools")
        answer("Gateway initialized.")
      end

    {:ok, empty_run} =
      OhMyJido.prompt(empty, empty_script.user, owned_options(empty_script, :atom))

    assert {:ok, %{status: :completed, tools: []}} =
             OhMyJido.await(empty, empty_run, timeout: 5_000)

    assert :ok = OhMyJido.stop_session(empty)

    {:ok, session} =
      OhMyJido.start_session(__MODULE__.Host,
        workspace: root,
        tools: [OhMyJido.Tools.Read, OhMyJido.Tools.Write],
        permissions: [:read, :edit]
      )

    script =
      expect_react do
        user("Write and inspect a file through the host-owned native gateway")
        call("write", %{path: "owned.txt", content: "written once\n", snapshot: "missing"})
        call("read", %{path: "owned.txt"})
        answer("Written and inspected.")
      end

    {:ok, run} = OhMyJido.prompt(session, script.user, owned_options(script, :keyword))

    assert {:ok,
            %{
              status: :completed,
              tools: [%{name: "write", status: :completed}, %{name: "read", status: :completed}]
            }} = OhMyJido.await(session, run, timeout: 5_000)

    assert File.read!(Path.join(root, "owned.txt")) == "written once\n"
    assert :ok = OhMyJido.stop_session(session)
    assert pool_pids(ReqLLM.Finch) == shared_pools

    owned_pools = pool_pids(__MODULE__.Finch)
    refute owned_pools == []

    workers =
      Enum.flat_map(owned_pools, fn pool ->
        for {_id, pid, _type, _modules} <- Supervisor.which_children(pool), is_pid(pid), do: pid
      end)

    monitors = Enum.map(owned_pools ++ workers, &{&1, Process.monitor(&1)})
    assert :ok = stop_supervised(__MODULE__.Finch)

    for {pid, monitor} <- monitors do
      assert_receive {:DOWN, ^monitor, :process, ^pid, _reason}, 5_000
    end

    assert pool_pids(ReqLLM.Finch) == shared_pools
  end

  defp owned_options(script, shape) do
    finch = if shape == :atom, do: __MODULE__.Finch, else: [name: __MODULE__.Finch]

    script
    |> react_opts()
    |> Keyword.update!(:llm_opts, &Keyword.put(&1, :req_http_options, finch: finch))
  end

  defp pool_pids(finch) do
    finch
    |> Finch.Pool.Manager.supervisor_name()
    |> Supervisor.which_children()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&is_pid/1)
    |> Enum.sort()
  end

  defp assert_native_descriptors(session) do
    {:ok, %{agent_pid: actor}} = OhMyJido.inspect_session(session)
    supervisor = Jido.agent_supervisor_name(Runtime.engine(session.runtime))
    children = Supervisor.which_children(supervisor)

    assert {_id, ^actor, :worker, [AgentServer]} = Enum.find(children, &(elem(&1, 1) == actor))

    lifecycles =
      for {_tag, %{lifecycle_pid: pid}} <- AgentServer.children(actor), is_pid(pid), do: pid

    refute lifecycles == []

    for lifecycle <- lifecycles do
      assert {_id, ^lifecycle, :worker, [Jido.AgentServer.PluginChild]} =
               Enum.find(children, &(elem(&1, 1) == lifecycle))
    end
  end
end
