defmodule OhMyJido.DelegationTest do
  use Jido.AI.TestCase, async: false
  alias OhMyJido.Runtime

  defmodule WaitingRead do
    use Jido.Action,
      name: "delegation_wait",
      description: "Hold an authorized child at an observable native tool boundary",
      schema: Zoi.object(%{})

    def capability, do: :read

    @impl true
    def run(_params, %{oh_my_jido: context} = execution_context) do
      with :ok <- OhMyJido.Tool.authorize(execution_context, :read) do
        send(context.metadata.observer, {:delegation_waiting, context.session_id, self()})

        receive do
          :release -> {:ok, %{released: true}}
        after
          15_000 -> {:error, :delegation_gate_deadline}
        end
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-delegate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!(
      {Runtime,
       name: __MODULE__.Host,
       allow_test_scripts: true,
       max_active: 3,
       max_subagents: 3,
       request_transformer: __MODULE__.ScriptedRequests}
    )

    %{root: root}
  end

  test "duplicate active child tags cannot replace parent ownership", %{root: root} do
    {:ok, parent} =
      OhMyJido.start_session(__MODULE__.Host,
        workspace: root,
        permissions: [:read, :delegate],
        tools: [WaitingRead],
        metadata: %{observer: self()}
      )

    original =
      expect_react do
        user("Hold the original child")
        call("delegation_wait", %{})
        answer("Original child released.")
      end

    duplicate =
      expect_react do
        user("Try to replace the tracked child")
        call("delegation_wait", %{})
        answer("Duplicate child released.")
      end

    {:ok, child} =
      OhMyJido.delegate(
        parent,
        "Hold the original child",
        Keyword.put(react_opts(original), :tag, "owned")
      )

    id = child.session.id
    assert_receive {:delegation_waiting, ^id, worker}, 5_000
    monitor = Process.monitor(worker)
    sessions = OhMyJido.list_sessions(__MODULE__.Host)

    assert {:error, {:tag_in_use, "owned"}} =
             OhMyJido.delegate(
               parent,
               "Try to replace the tracked child",
               Keyword.put(react_opts(duplicate), :tag, "owned")
             )

    assert OhMyJido.list_sessions(__MODULE__.Host) == sessions

    assert {:ok, %{children: %{"owned" => %{session: %{id: ^id}, status: :running}}}} =
             OhMyJido.inspect_session(parent)

    assert {:ok, %{agent_pid: child_agent}} = OhMyJido.inspect_session(child.session)

    assert %{runtime: %{parent: %{id: parent_id}}} = Jido.AgentServer.status(child_agent)

    assert parent_id == parent.id
    send(worker, :release)

    assert {:ok, %{status: :completed, answer: "Original child released."}} =
             OhMyJido.await_child(parent, "owned", timeout: 5_000)

    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 5_000
    refute_receive {:delegation_waiting, _id, _worker}
  end

  test "a freed native tag remains reserved until its original completion is collected", %{
    root: root
  } do
    {:ok, parent} =
      OhMyJido.start_session(__MODULE__.Host,
        workspace: root,
        permissions: [:read, :delegate],
        tools: [WaitingRead],
        metadata: %{observer: self()}
      )

    original =
      expect_react do
        user("Hold the dying native child")
        call("delegation_wait", %{})
        answer("Original completed.")
      end

    replacement =
      expect_react do
        user("Hold the replacement child")
        call("delegation_wait", %{})
        answer("Replacement completed.")
      end

    {:ok, child} =
      OhMyJido.delegate(parent, original.user, Keyword.put(react_opts(original), :tag, "reused"))

    id = child.session.id
    assert_receive {:delegation_waiting, ^id, worker}, 5_000
    {:ok, context} = OhMyJido.Session.call(child.session, :context)
    {:ok, %{agent_pid: agent}} = OhMyJido.inspect_session(child.session)
    {:ok, %{agent_pid: parent_agent}} = OhMyJido.inspect_session(parent)
    monitor = Process.monitor(agent)
    :ok = :sys.suspend(context.coordinator)

    try do
      Process.exit(agent, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^agent, :killed}, 5_000
      send(worker, :release)

      wait_until(fn ->
        not Map.has_key?(Jido.AgentServer.children(parent_agent), "reused")
      end)

      assert {:error, {:tag_in_use, "reused"}} =
               OhMyJido.delegate(
                 parent,
                 replacement.user,
                 Keyword.put(react_opts(replacement), :tag, "reused")
               )

      assert {:ok, %{children: %{"reused" => %{session: %{id: ^id}, run: run}}}} =
               OhMyJido.inspect_session(parent)

      assert run == child.run
    after
      :sys.resume(context.coordinator)
      send(worker, :release)
    end

    assert {:error, _interrupted} =
             original_result = OhMyJido.await_child(parent, "reused", timeout: 5_000)

    wait_until(fn ->
      {:ok, snapshot} = OhMyJido.inspect_session(parent)
      snapshot.children["reused"].status == :completed
    end)

    assert {:ok, %{agent_pid: recovered_agent}} = OhMyJido.inspect_session(child.session)
    refute recovered_agent == agent
    recovered_monitor = Process.monitor(recovered_agent)

    # Killing the actor can destroy its Exec closure receipt. Tag collection
    # permits replacement; it must not invent proof that the old effect settled.
    assert {:error,
            %{
              reason: :cleanup_uncertain,
              native: :confirmed,
              pending_effects: ["tc_1"],
              pending_resources: []
            }} = OhMyJido.stop_session(child.session)

    assert_receive {:DOWN, ^recovered_monitor, :process, ^recovered_agent, _reason}, 5_000

    assert {:ok, %{agent_pid: nil, effects: %{"tc_1" => interrupted_effect}}} =
             OhMyJido.inspect_session(child.session)

    refute Map.has_key?(interrupted_effect, :completed_at)
    refute Map.has_key?(Jido.AgentServer.children(parent_agent), "reused")

    assert {:error, :session_stopped} = OhMyJido.Session.call(child.session, :context)
    assert Process.alive?(parent_agent)

    {:ok, next} =
      OhMyJido.delegate(
        parent,
        replacement.user,
        Keyword.put(react_opts(replacement), :tag, "reused")
      )

    next_id = next.session.id
    assert_receive {:delegation_waiting, ^next_id, next_worker}, 5_000

    assert {:error, :stale_child_result} =
             OhMyJido.Session.call(
               parent,
               {:child_result, "reused", child.session, child.run, original_result}
             )

    assert {:ok, %{children: %{"reused" => %{session: %{id: ^next_id}, status: :running}}}} =
             OhMyJido.inspect_session(parent)

    send(next_worker, :release)

    assert {:ok, %{answer: "Replacement completed."}} =
             OhMyJido.await_child(parent, "reused", timeout: 5_000)
  end

  defmodule GatedHost do
    @behaviour OhMyJido.Host

    @impl true
    def authorize(context, :read, %{operation: :read, path: "gate-" <> _rest} = effect, opts) do
      token = make_ref()

      send(
        Keyword.fetch!(opts, :observer),
        {:delegation_read_gate, context.session_id, self(), token, context.workspace, effect.path}
      )

      receive do
        {:release_delegation_read, ^token} -> :ok
      after
        15_000 -> {:error, :delegation_gate_deadline}
      end
    end

    def authorize(context, capability, effect, opts),
      do: OhMyJido.Host.Local.authorize(context, capability, effect, opts)

    @impl true
    defdelegate credentials(context, account, opts), to: OhMyJido.Host.Local
    @impl true
    defdelegate invoke(context, capability, request, opts), to: OhMyJido.Host.Local
    @impl true
    defdelegate question(context, question, opts), to: OhMyJido.Host.Local
  end

  defmodule ScriptedRequests do
    @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

    @impl true
    def transform_request(request, state, config, %{oh_my_jido: context} = runtime_context) do
      query =
        request.messages
        |> Enum.reverse()
        |> Enum.find_value(fn
          %{role: :user, content: content} ->
            Jido.AI.Model.Response.extract_from_content(content)

          _message ->
            nil
        end)

      request =
        case Map.get(context.metadata, :delegation_scripts, %{})[query] do
          nil ->
            request

          script ->
            %{
              request
              | llm_opts: Keyword.merge(request.llm_opts, Jido.AI.Test.react_llm_opts(script))
            }
        end

      with {:ok, projected} <-
             OhMyJido.Models.Transformer.transform_request(
               request,
               state,
               config,
               runtime_context
             ) do
        if observer = context.metadata[:observer] do
          send(observer, {:delegation_model_request, context.session_id, context.role, query})
        end

        {:ok, projected}
      end
    end
  end

  test "T5: overlapping native readers and an isolated writer remain parent-controlled through cancellation",
       %{root: root} do
    %{parent: parent, parent_root: parent_root, isolated_root: isolated_root} =
      consumer_parent(root)

    first = reader_script("Read first repository fact", "gate-one.txt", "First fact collected.")

    second =
      reader_script("Read second repository fact", "gate-two.txt", "Second fact collected.")

    edit = edit_params("gate-write.txt", "isolated before\n", "isolated changed\n")

    writer =
      expect_react do
        user("Change only the isolated file")
        call("read", %{path: "gate-write.txt"})
        call("edit", edit)
        answer("Isolated edit completed.")
      end

    assert {:ok, one} =
             OhMyJido.delegate(
               parent,
               first.user,
               Keyword.put(react_opts(first), :tag, "reader-one")
             )

    assert {:ok, two} =
             OhMyJido.delegate(
               parent,
               second.user,
               Keyword.put(react_opts(second), :tag, "reader-two")
             )

    assert {:ok, writer} =
             OhMyJido.delegate(
               parent,
               writer.user,
               Keyword.merge(react_opts(writer),
                 tag: "writer",
                 role: :coding,
                 writable: true,
                 permissions: [:read, :edit],
                 workspace: isolated_root
               )
             )

    # No gate is released until all three native tool workers have arrived.
    gates = Enum.map([one, two, writer], &read_gate/1)
    assert gates |> Enum.map(& &1.worker) |> Enum.uniq() |> length() == 3
    assert Enum.all?(gates, &Process.alive?(&1.worker))

    assert {:ok, %{children: children, status: :idle}} = OhMyJido.inspect_session(parent)
    assert map_size(children) == 3
    assert Enum.all?(children, fn {_tag, child} -> child.status == :running end)

    for child <- [one, two, writer] do
      run = child.run

      assert {:ok, %{status: :running, active_run: ^run, agent_pid: child_agent}} =
               OhMyJido.inspect_session(child.session)

      assert %{runtime: %{parent: %{id: parent_id}}} = Jido.AgentServer.status(child_agent)

      assert parent_id == parent.id
    end

    assert one.workspace == parent_root
    assert two.workspace == parent_root
    assert writer.workspace == isolated_root
    assert writer.workspace != parent_root
    assert {:ok, %{permissions: [:read]}} = OhMyJido.inspect_session(one.session)
    assert {:ok, %{permissions: [:read]}} = OhMyJido.inspect_session(two.session)
    assert {:ok, %{permissions: [:edit, :read]}} = OhMyJido.inspect_session(writer.session)

    assert {:error, {:capacity, :subagent}} =
             OhMyJido.delegate(parent, "Do not admit a fourth active child")

    assert {:error, :timeout} = OhMyJido.await_child(parent, one.tag, timeout: 1)
    assert Enum.all?(gates, &Process.alive?(&1.worker))
    Enum.each(gates, &release_read/1)

    assert {:ok, %{answer: "First fact collected.", status: :completed} = first_result} =
             OhMyJido.await_child(parent, one.tag, timeout: 5_000)

    assert {:ok, %{answer: "Second fact collected.", status: :completed} = second_result} =
             OhMyJido.await_child(parent, two.tag, timeout: 5_000)

    assert {:ok, %{answer: "Isolated edit completed.", status: :completed} = writer_result} =
             OhMyJido.await_child(parent, writer.tag, timeout: 5_000)

    assert_collected(parent, one.tag, {:ok, first_result})
    assert_collected(parent, two.tag, {:ok, second_result})
    assert_collected(parent, writer.tag, {:ok, writer_result})
    assert [%{content: "known repository fact\n"}] = completed_results(one.session, "read")
    assert [%{content: "second repository fact\n"}] = completed_results(two.session, "read")
    assert [%{content: "isolated before\n"}] = completed_results(writer.session, "read")
    assert [%{replacements: 1}] = completed_results(writer.session, "edit")
    assert File.read!(Path.join(parent_root, "gate-write.txt")) == "parent baseline\n"
    assert File.read!(Path.join(isolated_root, "gate-write.txt")) == "isolated changed\n"

    assert {:error,
            %Jido.Action.Error.ExecutionFailureError{
              details: %{reason: {:permission_denied, :edit}}
            }} =
             OhMyJido.execute_tool(one.session, "edit", edit)

    assert {:error,
            %Jido.Action.Error.ExecutionFailureError{details: %{reason: :outside_workspace}}} =
             OhMyJido.execute_tool(writer.session, "read", %{
               path: Path.join(parent_root, "facts.txt")
             })

    interrupted_edit =
      edit_params("facts.txt", "isolated fact\n", "applied before cancellation\n")

    command = %{
      executable: "sh",
      args: ["-c", "printf 'once\\n' >> cancelled-effect; sleep 30 & echo $! > child; wait"],
      timeout_ms: 15_000
    }

    cancellable =
      expect_react do
        user("Apply an isolated edit and wait for parent control")
        call("read", %{path: "facts.txt"})
        call("edit", interrupted_edit)
        call("shell", command)
        answer("The parent allowed completion.")
      end

    assert {:ok, active} =
             OhMyJido.delegate(
               parent,
               cancellable.user,
               Keyword.merge(react_opts(cancellable),
                 tag: "cancelled-writer",
                 role: :coding,
                 writable: true,
                 workspace: isolated_root,
                 permissions: [:read, :edit, :exec]
               )
             )

    child = ready_process(isolated_root)
    assert process_alive?(child)
    assert File.read!(Path.join(isolated_root, "facts.txt")) == "applied before cancellation\n"
    assert File.read!(Path.join(parent_root, "facts.txt")) == "known repository fact\n"

    assert {:ok, %{children: %{"cancelled-writer" => %{status: :running}}}} =
             OhMyJido.inspect_session(parent)

    assert :ok = OhMyJido.steer_child(parent, active.tag, "Do not perform another edit.")

    assert {:ok, %{status: :cancellation_requested}} =
             OhMyJido.execute_tool(parent, "subagent", %{operation: "cancel", tag: active.tag})

    wait_until(fn -> not process_alive?(child) end)

    assert {:error, %{status: :cancelled} = cancelled} =
             OhMyJido.await_child(parent, active.tag, timeout: 5_000)

    assert_collected(parent, active.tag, {:error, cancelled})
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(active.session)
    assert [%{status: :completed}] = effects_named(effects, "edit")
    assert [%{status: :uncertain}] = effects_named(effects, "shell")
    assert File.read!(Path.join(isolated_root, "cancelled-effect")) == "once\n"

    continued_effects =
      child_continues_without_replay(
        active.session,
        "Inspect the cancelled outcome without another edit",
        [{"read", %{path: "facts.txt"}}, {"edit", interrupted_edit}],
        "applied before cancellation\n"
      )

    assert Map.take(continued_effects, Map.keys(effects)) == effects

    parent_continues(parent, "Parent continues after child cancellation")
    assert File.read!(Path.join(parent_root, "facts.txt")) == "parent continued\n"
    assert File.read!(Path.join(isolated_root, "facts.txt")) == "applied before cancellation\n"
    assert {:ok, %{effects: ^continued_effects}} = OhMyJido.inspect_session(active.session)
    assert File.read!(Path.join(isolated_root, "cancelled-effect")) == "once\n"
  end

  test "D12: parent executes review and advisor children and applies distinct native steering",
       %{root: root} do
    review = reader_script("Review the repository change", "gate-review.txt", "Review completed.")

    advisor =
      reader_script("Advise on the change", "gate-advisor.txt", "Initial advice completed.")

    steering = "Read policy.txt before giving final advice; leave all files unchanged."

    steered =
      expect_react do
        user(steering)
        # The first read is already in the native transcript when steering arrives.
        call("read", %{path: "gate-advisor.txt"})
        call("read", %{path: "policy.txt"})
        answer("Policy inspected; the parent retains the edit decision.")
      end

    scripts = %{review.user => review, advisor.user => advisor, steering => steered}

    %{parent: parent, parent_root: parent_root} = consumer_parent(root, scripts)

    assert {:ok, review_child} =
             OhMyJido.execute_tool(parent, "subagent", %{
               operation: "start",
               tag: "review",
               role: "review",
               task: review.user
             })

    assert {:ok, advisor_child} =
             OhMyJido.execute_tool(parent, "subagent", %{
               operation: "start",
               tag: "advisor",
               role: "advisor",
               task: advisor.user
             })

    review_ref = %OhMyJido.SessionRef{runtime: parent.runtime, id: review_child.session_id}
    advisor_ref = %OhMyJido.SessionRef{runtime: parent.runtime, id: advisor_child.session_id}
    review_gate = read_gate(%{session: review_ref})
    advisor_gate = read_gate(%{session: advisor_ref})
    assert Process.alive?(review_gate.worker)
    assert Process.alive?(advisor_gate.worker)

    assert {:ok, %{role: :review, permissions: [:read], status: :running}} =
             OhMyJido.inspect_session(review_ref)

    assert {:ok, %{role: :advisor, permissions: [:read], status: :running}} =
             OhMyJido.inspect_session(advisor_ref)

    assert {:ok, %{status: :idle, role: :coding}} = OhMyJido.inspect_session(parent)

    assert {:error, %Jido.Action.Error.ExecutionFailureError{details: %{reason: :timeout}}} =
             OhMyJido.execute_tool(parent, "subagent", %{
               operation: "wait",
               tag: "review",
               timeout: 1
             })

    assert {:ok, %{status: :queued}} =
             OhMyJido.execute_tool(parent, "subagent", %{
               operation: "steer",
               tag: "advisor",
               text: steering
             })

    release_read(review_gate)
    release_read(advisor_gate)

    assert {:ok, %{status: :completed, answer: "Review completed."} = review_result} =
             OhMyJido.execute_tool(parent, "subagent", %{
               operation: "wait",
               tag: "review",
               timeout: 5_000
             })

    assert {:ok,
            %{
              status: :completed,
              answer: "Policy inspected; the parent retains the edit decision."
            } = advisor_result} =
             OhMyJido.await_child(parent, "advisor", timeout: 5_000)

    assert_collected(parent, "review", {:ok, review_result})
    assert_collected(parent, "advisor", {:ok, advisor_result})

    assert [%{content: "review target: keep parent ownership\n"}] =
             completed_results(review_ref, "read")

    advisor_contents = Enum.map(completed_results(advisor_ref, "read"), & &1.content)

    assert Enum.sort(advisor_contents) ==
             Enum.sort(["advisor target: validate scope\n", "Only parent may edit facts.txt.\n"])

    advisor_id = advisor_ref.id
    assert_receive {:delegation_model_request, ^advisor_id, :advisor, ^steering}, 5_000
    assert Enum.any?(OhMyJido.events(advisor_ref), &(&1.kind == :input_injected))

    assert {:error, {:permission_denied, :delegate}} =
             OhMyJido.delegate(review_ref, "Reviewers cannot create another agent")

    assert {:error,
            %Jido.Action.Error.ExecutionFailureError{
              details: %{reason: {:permission_denied, :edit}}
            }} =
             OhMyJido.execute_tool(
               advisor_ref,
               "edit",
               edit_params("facts.txt", "known repository fact\n", "helper must not write\n")
             )

    assert File.read!(Path.join(parent_root, "facts.txt")) == "known repository fact\n"
    parent_continues(parent, "Parent decides after review and advice")
    assert File.read!(Path.join(parent_root, "facts.txt")) == "parent continued\n"
    assert {:ok, %{status: :idle, role: :coding}} = OhMyJido.inspect_session(parent)
  end

  test "failed child results retain completed edits without replay or parent failure", %{
    root: root
  } do
    %{parent: parent, parent_root: parent_root, isolated_root: isolated_root} =
      consumer_parent(root)

    edit = edit_params("facts.txt", "isolated fact\n", "completed before model failure\n")

    script =
      expect_react do
        user("Edit an isolated file before the model fails")
        call("read", %{path: "facts.txt"})
        call("edit", edit)
        fail(%{type: :delegation_fixture_failure, message: "The model stopped after the edit."})
      end

    assert {:ok, child} =
             OhMyJido.delegate(
               parent,
               script.user,
               Keyword.merge(react_opts(script),
                 tag: "failed",
                 writable: true,
                 workspace: isolated_root
               )
             )

    assert {:error, %{status: :failed, error: error} = failed} =
             OhMyJido.await_child(parent, child.tag, timeout: 5_000)

    refute is_nil(error)
    assert_collected(parent, child.tag, {:error, failed})
    assert [%{replacements: 1}] = completed_results(child.session, "edit")
    assert File.read!(Path.join(isolated_root, "facts.txt")) == "completed before model failure\n"
    assert File.read!(Path.join(parent_root, "facts.txt")) == "known repository fact\n"
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(child.session)

    continued_effects =
      child_continues_without_replay(
        child.session,
        "Inspect the failed outcome without another edit",
        [{"read", %{path: "facts.txt"}}, {"edit", edit}],
        "completed before model failure\n"
      )

    assert Map.take(continued_effects, Map.keys(effects)) == effects

    parent_continues(parent, "Parent continues after child model failure")
    assert {:ok, %{effects: ^continued_effects}} = OhMyJido.inspect_session(child.session)
    assert File.read!(Path.join(isolated_root, "facts.txt")) == "completed before model failure\n"
  end

  test "delegation rejects escalated grants, ungranted roots, and exhausted depth", %{root: root} do
    %{parent: parent, parent_root: parent_root} = consumer_parent(root)
    ungranted = Path.join(root, "ungranted")
    File.mkdir_p!(ungranted)
    sessions = OhMyJido.list_sessions(parent.runtime)

    assert {:error, :permission_escalation} =
             OhMyJido.delegate(parent, "Escalate", writable: true, permissions: [:eval])

    assert {:error, :read_only_child} =
             OhMyJido.delegate(parent, "Smuggle edit into a reader", permissions: [:edit])

    assert {:error, :child_workspace_not_granted} =
             OhMyJido.delegate(parent, "Write in the parent",
               writable: true,
               workspace: parent_root
             )

    assert {:error, :child_workspace_not_granted} =
             OhMyJido.delegate(parent, "Use an ungranted sibling",
               writable: true,
               workspace: ungranted
             )

    assert OhMyJido.list_sessions(parent.runtime) == sessions
    assert File.read!(Path.join(parent_root, "facts.txt")) == "known repository fact\n"

    assert {:ok, at_depth_limit} =
             OhMyJido.start_session(parent.runtime,
               workspace: parent_root,
               permissions: [:read, :delegate],
               metadata: %{delegation_depth: 2}
             )

    assert {:error, :delegation_depth} =
             OhMyJido.delegate(at_depth_limit, "Do not bypass the default depth bound")

    assert {:error, :unknown_child} = OhMyJido.await_child(parent, "not-started")
    assert {:error, :unknown_child} = OhMyJido.steer_child(parent, "not-started", "No effect")
    assert {:error, :unknown_child} = OhMyJido.cancel_child(parent, "not-started")
  end

  defp consumer_parent(root, scripts \\ %{}) do
    parent_root = Path.join(root, "consumer")
    isolated_root = Path.join(root, "isolated")
    File.mkdir_p!(parent_root)
    File.mkdir_p!(isolated_root)

    for {path, content} <- [
          {"facts.txt", "known repository fact\n"},
          {"gate-one.txt", "known repository fact\n"},
          {"gate-two.txt", "second repository fact\n"},
          {"gate-write.txt", "parent baseline\n"},
          {"gate-review.txt", "review target: keep parent ownership\n"},
          {"gate-advisor.txt", "advisor target: validate scope\n"},
          {"policy.txt", "Only parent may edit facts.txt.\n"}
        ] do
      File.write!(Path.join(parent_root, path), content)
    end

    File.write!(Path.join(isolated_root, "facts.txt"), "isolated fact\n")
    File.write!(Path.join(isolated_root, "gate-write.txt"), "isolated before\n")

    assert {:ok, parent} =
             OhMyJido.start_session(__MODULE__.Host,
               workspace: parent_root,
               permissions: [:read, :edit, :exec, :delegate],
               tools: [
                 OhMyJido.Tools.Read,
                 OhMyJido.Tools.Edit,
                 OhMyJido.Tools.Subagent,
                 OhMyJido.Tools.Shell
               ],
               host: {GatedHost, observer: self()},
               metadata: %{
                 observer: self(),
                 delegation_roots: [isolated_root],
                 delegation_scripts: scripts
               }
             )

    assert :ok = OhMyJido.subscribe(parent, self())
    %{parent: parent, parent_root: parent_root, isolated_root: isolated_root}
  end

  defp reader_script(task, path, result) do
    expect_react do
      user(task)
      call("read", %{path: path})
      answer(result)
    end
  end

  defp edit_params(path, before, after_content) do
    %{
      path: path,
      snapshot: OhMyJido.Files.snapshot(before),
      edits: [%{old: before, new: after_content}]
    }
  end

  defp read_gate(child) do
    id = child.session.id

    assert_receive {:delegation_read_gate, ^id, worker, token, workspace, path}, 5_000
    %{worker: worker, token: token, workspace: workspace, path: path}
  end

  defp release_read(gate),
    do: send(gate.worker, {:release_delegation_read, gate.token})

  defp assert_collected(parent, tag, result) do
    id = parent.id

    assert_receive {:oh_my_jido,
                    %OhMyJido.Event{
                      session_id: ^id,
                      kind: :subagent_completed,
                      payload: %{tag: ^tag, result: ^result}
                    }},
                   5_000

    assert {:ok, %{children: children}} = OhMyJido.inspect_session(parent)
    assert %{status: :completed, result: ^result} = Map.fetch!(children, tag)
  end

  defp completed_results(session, name) do
    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)

    effects
    |> effects_named(name)
    |> Enum.map(fn effect ->
      assert effect.status == :completed
      effect_result(effect.result)
    end)
  end

  defp effects_named(effects, name),
    do: effects |> Map.values() |> Enum.filter(&(&1.name == name))

  defp effect_result({:ok, result}), do: result
  defp effect_result({:ok, result, _effects}), do: result

  defp child_continues_without_replay(session, task, preceding_calls, content) do
    script =
      expect_react do
        user(task)
        # Native scripts count the tool turns retained from the preceding run.
        for {name, params} <- preceding_calls, do: call(name, params)
        call("read", %{path: "facts.txt"}, id: "continued-read")
        answer("Inspected the retained outcome without replay.")
      end

    assert {:ok, run} = OhMyJido.prompt(session, task, react_opts(script))

    assert {:ok,
            %{
              status: :completed,
              answer: "Inspected the retained outcome without replay.",
              tools: [%{name: "read", status: :completed}]
            }} = OhMyJido.await(session, run, timeout: 5_000)

    assert {:ok, %{effects: effects}} = OhMyJido.inspect_session(session)
    assert [read] = Enum.filter(Map.values(effects), &(&1.run == run))
    assert %{content: ^content} = effect_result(read.result)
    effects
  end

  defp parent_continues(parent, task) do
    edit = edit_params("facts.txt", "known repository fact\n", "parent continued\n")

    script =
      expect_react do
        user(task)
        call("read", %{path: "facts.txt"})
        call("edit", edit)
        answer("Parent continued with its own guarded edit.")
      end

    assert {:ok, run} = OhMyJido.prompt(parent, task, react_opts(script))

    assert {:ok, %{status: :completed, answer: "Parent continued with its own guarded edit."}} =
             OhMyJido.await(parent, run, timeout: 5_000)

    assert [%{replacements: 1}] = completed_results(parent, "edit")
  end

  defp ready_process(root) do
    path = Path.join(root, "child")
    wait_until(fn -> match?({:ok, content} when content != "", File.read(path)) end)
    path |> File.read!() |> String.trim() |> String.to_integer()
  end

  defp process_alive?(pid) do
    case OhMyJido.Process.capture_identity(pid) do
      {:ok, %{state: state}} -> state not in ["Z", "X"]
      {:error, :enoent} -> false
    end
  end

  defp wait_until(predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    if predicate.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      wait_until(predicate, deadline)
    end
  end
end
