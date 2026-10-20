defmodule OhMyJidoDocs.EditorTest do
  use OhMyJidoDocs.DataCase, async: false

  import Jido.AI.Test

  alias OhMyJido.{Runtime, SessionRef}
  alias OhMyJidoDocs.{Editor, Repo, Workspaces}
  alias OhMyJidoDocs.Editor.{Host, Run, RunEvent, WriterLease}

  @runtime OhMyJidoDocs.Coding
  @moduletag timeout: 60_000

  setup do
    root = Path.join(System.tmp_dir!(), "docs-editor-#{Ecto.UUID.generate()}")
    source = Path.join(root, "source")
    app = Path.join(source, "examples/docs_site")
    File.mkdir_p!(Path.join(app, "priv/docs"))
    File.mkdir_p!(Path.join(app, "lib"))
    File.write!(Path.join(app, "priv/docs/index.md"), "# Guide\n\nA typo lives here.\n")
    File.write!(Path.join(app, "lib/untouched.ex"), "defmodule Untouched, do: nil\n")

    File.write!(
      Path.join(app, "mix.exs"),
      "defmodule Fixture.MixProject do\n  use Mix.Project\n  def project, do: [app: :editor_fixture, version: \"0.1.0\"]\nend\n"
    )

    File.write!(
      Path.join(source, "mix.exs"),
      "defmodule FixtureRoot.MixProject do\n  use Mix.Project\n  def project, do: [app: :editor_fixture_root, version: \"0.1.0\"]\nend\n"
    )

    git!(source, ["init", "--quiet"])
    git!(source, ["add", "."])

    git!(source, [
      "-c",
      "user.name=Editor Test",
      "-c",
      "user.email=editor@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "Initial docs"
    ])

    settings = [:source_root, :source_app_path, :data_dir, :model, :model_api_key, :model_account]
    previous = Map.new(settings, &{&1, Application.fetch_env(:oh_my_jido_docs, &1)})
    Application.put_env(:oh_my_jido_docs, :source_root, source)
    Application.put_env(:oh_my_jido_docs, :source_app_path, "examples/docs_site")
    Application.put_env(:oh_my_jido_docs, :data_dir, Path.join(root, "data"))
    Application.put_env(:oh_my_jido_docs, :model, "anthropic:claude-haiku-4-5")
    Application.put_env(:oh_my_jido_docs, :model_api_key, nil)
    Application.put_env(:oh_my_jido_docs, :model_account, "docs-site")

    {:ok, runtime_config} = Runtime.config(@runtime)

    test_config =
      Keyword.merge(runtime_config,
        name: @runtime,
        allow_test_scripts: true,
        max_active: 2,
        max_sessions: 8,
        max_processes: 2,
        context_policy: [max_messages: 80, keep_recent: 80, max_bytes: 256_000],
        storage: {Jido.Persistence.File, path: Path.join(root, "sessions")}
      )

    :ok = OhMyJidoDocs.DataCase.restart_private_workers(test_config)

    on_exit(fn ->
      for run <- Editor.list_runs() do
        if run.status in ~w(queued running waiting) do
          assert Editor.cancel_run(run.id) in [:ok, {:error, :run_not_active}]
        end

        await_snapshot(run.id, fn snapshot ->
          snapshot.run.status not in ~w(queued running waiting cancelling suspending) and
            not snapshot.run.source_writer_pending and is_nil(snapshot.run.source_writer_token) and
            not snapshot.run.workspace_cleanup_pending
        end)
      end

      sessions = if Process.whereis(@runtime), do: OhMyJido.list_sessions(@runtime), else: []

      for session <- sessions do
        assert :ok = OhMyJido.stop_session(session)

        case Repo.get_by(Run, session_id: session.id) do
          %Run{source_writer_pending: true} = run ->
            assert :ok =
                     Editor.reconcile_writer(
                       run.id,
                       run.source_writer_token,
                       :orphan_resources_reconciled
                     )

          _settled ->
            :ok
        end
      end

      :ok = OhMyJidoDocs.DataCase.stop_private_workers()

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:oh_my_jido_docs, key, value)
        {key, :error} -> Application.delete_env(:oh_my_jido_docs, key)
      end)

      :ok = OhMyJidoDocs.Candidates.Source.remove_tree(root)
    end)

    %{source: source, root: root}
  end

  test "queued cancellation retains its creator until the owned allocation is discarded" do
    queued_cancel(false)
  end

  test "queued cancellation cleanup survives observer restart without overtaking its creator" do
    queued_cancel(true)
  end

  test "an explicit model edits only isolated Git-backed Markdown without global native aliases",
       %{
         source: source
       } do
    aliases = Application.fetch_env(:jido_ai, :model_aliases)
    Application.delete_env(:jido_ai, :model_aliases)

    on_exit(fn ->
      case aliases do
        {:ok, value} -> Application.put_env(:jido_ai, :model_aliases, value)
        :error -> Application.delete_env(:jido_ai, :model_aliases)
      end
    end)

    assert Jido.AI.Models.aliases() == %{}
    original = "# Guide\n\nA typo lives here.\n"

    script =
      expect_react do
        user("Repair the guide")
        call("read", %{path: "priv/docs/index.md"})

        call("edit", %{
          path: "priv/docs/index.md",
          snapshot: OhMyJido.Files.snapshot(original),
          edits: [%{old: "A typo lives here.", new: "The guide is corrected."}]
        })

        answer("Corrected the guide in the source workspace.")
      end

    assert {:ok, run} =
             Editor.start_run(%{task: "Repair the guide", mode: "docs"}, react_opts(script))

    assert run.status == "queued"
    :ok = Editor.subscribe(run.id)

    snapshot =
      await_snapshot(run.id, &(&1.run.status == "completed" and is_binary(&1.run.summary)))

    assert File.read!(Path.join(snapshot.run.workspace, "priv/docs/index.md")) =~
             "The guide is corrected."

    assert File.read!(Path.join(source, "examples/docs_site/priv/docs/index.md")) == original
    assert snapshot.run.base_revision != ""
    assert snapshot.run.summary =~ "Corrected the guide"
    assert Enum.any?(snapshot.events, &(&1.kind == "run_completed"))
    assert Enum.any?(snapshot.events, &(&1.kind == "checkpoint_saved"))

    assert snapshot.events |> Enum.map(& &1.seq) |> Enum.uniq() |> length() ==
             length(snapshot.events)

    assert Repo.aggregate(from(e in RunEvent, where: e.run_id == ^run.id), :count) > 0
    refute inspect(snapshot, limit: :infinity) =~ "agent_pid"
  end

  test "clarification survives subscriber disconnect and answers through the native tool" do
    script =
      expect_react do
        user("Ask before choosing the title")
        call("question", %{question: "Which title should the guide use?", options: []})

        call("write", %{
          path: "priv/docs/title.md",
          content: "# Human-selected title\n",
          snapshot: "missing"
        })

        answer("The human-selected title was written.")
      end

    {:ok, run} = Editor.start_run(%{task: "Ask before choosing the title"}, react_opts(script))

    subscriber =
      spawn(fn ->
        Editor.subscribe(run.id)

        receive do
          :stop -> :ok
        end
      end)

    snapshot = await_snapshot(run.id, &(&1.pending_questions != []))
    Process.exit(subscriber, :kill)

    assert [%{id: question_id, question: %{"question" => "Which title should the guide use?"}}] =
             snapshot.pending_questions

    assert Editor.answer(run.id, "another-question", "A title") == {:error, :unknown_question}
    assert :ok = Editor.answer(run.id, question_id, "Human-selected title")
    completed = await_snapshot(run.id, &(&1.run.status == "completed"))
    assert completed.pending_questions == []

    assert File.read!(Path.join(completed.run.workspace, "priv/docs/title.md")) ==
             "# Human-selected title\n"

    assert Enum.any?(completed.events, &(&1.kind == "approval_answered"))
  end

  test "the host observer reconnects to a live native question after its own restart" do
    script =
      expect_react do
        user("Keep the native question alive")

        call("write", %{
          path: "priv/docs/before-reconnect.md",
          content: "written before reconnect\n",
          snapshot: "missing"
        })

        call("question", %{question: "Continue after reconnect?"})

        call("write", %{
          path: "priv/docs/after-reconnect.md",
          content: "written after reconnect\n",
          snapshot: "missing"
        })

        answer("The native session survived the observer restart.")
      end

    {:ok, run} = Editor.start_run(%{task: "Keep the native question alive"}, react_opts(script))
    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    [%{id: question_id}] = waiting.pending_questions
    assert {:ok, holder} = WriterLease.lookup(Editor.get_run!(run.id))
    observer = Process.whereis(OhMyJidoDocs.Editor.Observer)
    monitor = Process.monitor(observer)
    Process.exit(observer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^observer, _}, 5_000
    :ok = Editor.subscribe(run.id)

    await_snapshot(run.id, fn snapshot ->
      is_pid(Process.whereis(OhMyJidoDocs.Editor.Observer)) and snapshot.run.status == "waiting"
    end)

    assert Process.alive?(holder.pid)
    assert {:ok, same_holder} = WriterLease.lookup(Editor.get_run!(run.id))
    assert same_holder.pid == holder.pid

    assert {:error, :workspace_busy} =
             Workspaces.freeze(waiting.run.workspace, "during-observer-reconnect")

    assert :ok = Editor.answer(run.id, question_id, "Continue")

    completed =
      await_snapshot(run.id, &(&1.run.status == "completed" and &1.session["status"] == "idle"))

    assert File.read!(Path.join(completed.run.workspace, "priv/docs/before-reconnect.md")) ==
             "written before reconnect\n"

    assert File.read!(Path.join(completed.run.workspace, "priv/docs/after-reconnect.md")) ==
             "written after reconnect\n"

    writes = Enum.filter(completed.session["effects"], &(&1["name"] == "write"))
    assert [_, _] = writes
  end

  @tag capture_log: true
  test "database unavailability quarantines a live native run without restart or replay" do
    script =
      expect_react do
        user("Keep the database-scoped native question")

        call("write", %{
          path: "priv/docs/before-database.md",
          content: "written before outage\n",
          snapshot: "missing"
        })

        call("question", %{question: "Continue when database ownership returns?"})

        call("write", %{
          path: "priv/docs/after-database.md",
          content: "written after recovery\n",
          snapshot: "missing"
        })

        answer("The same native execution survived database recovery.")
      end

    assert {:ok, run} =
             Editor.start_run(
               %{task: "Keep the database-scoped native question"},
               react_opts(script)
             )

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    [%{id: question_id}] = waiting.pending_questions
    observer = Process.whereis(OhMyJidoDocs.Editor.Observer)
    monitor = Process.monitor(observer)
    assert {:ok, holder} = WriterLease.lookup(Editor.get_run!(run.id))

    :sys.replace_state(observer, fn state ->
      Repo.put_dynamic_repo(__MODULE__.UnavailableRepo)
      %{state | boot?: true}
    end)

    try do
      send(observer, :reconcile_now)
      assert {:error, :writer_state_unavailable} = Editor.answer(run.id, question_id, "not yet")
      assert {:error, :writer_state_unavailable} = Editor.cancel_run(run.id)
      for _attempt <- 1..3, do: send(observer, :reconcile_now)
      assert :sys.get_state(observer).database_unavailable?
      assert Process.whereis(OhMyJidoDocs.Editor.Observer) == observer
      assert Process.alive?(holder.pid)
      assert Editor.get_run!(run.id).source_writer_pending
      assert {:error, :workspace_busy} = Editor.source_write_settled(waiting.run.workspace)

      assert File.read!(Path.join(waiting.run.workspace, "priv/docs/before-database.md")) ==
               "written before outage\n"

      refute File.exists?(Path.join(waiting.run.workspace, "priv/docs/after-database.md"))
      refute_receive {:DOWN, ^monitor, :process, ^observer, _reason}, 0
    after
      :sys.replace_state(observer, fn state ->
        Repo.put_dynamic_repo(Repo)
        state
      end)

      send(observer, :reconcile_now)
    end

    assert :ok = Editor.answer(run.id, question_id, "Continue the existing native execution")

    completed =
      await_snapshot(run.id, &(&1.run.status == "completed" and not &1.run.source_writer_pending))

    assert File.read!(Path.join(completed.run.workspace, "priv/docs/after-database.md")) ==
             "written after recovery\n"

    assert [_, _] = Enum.filter(completed.session["effects"], &(&1["name"] == "write"))
    assert Process.whereis(OhMyJidoDocs.Editor.Observer) == observer
    Process.demonitor(monitor, [:flush])
  end

  test "private worker shutdown settles actual native work while its sandbox is still available" do
    script =
      expect_react do
        user("Stop the private owner before its database")

        call("write", %{
          path: "priv/docs/before-shutdown.md",
          content: "real owned source\n",
          snapshot: "missing"
        })

        call("question", %{question: "This continuation must not be replayed"})

        call("write", %{
          path: "priv/docs/after-shutdown.md",
          content: "must not execute\n",
          snapshot: "missing"
        })

        answer("This request must remain interrupted.")
      end

    assert {:ok, run} =
             Editor.start_run(
               %{task: "Stop the private owner before its database"},
               react_opts(script)
             )

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    assert {:ok, holder} = WriterLease.lookup(Editor.get_run!(run.id))
    native_pid = holder.native_pid
    assert :ok = OhMyJidoDocs.DataCase.stop_private_workers()
    refute Process.alive?(native_pid)
    refute Process.alive?(holder.pid)

    # These real queries happen after every private child has stopped but before
    # DataCase releases the sandbox owner.
    stopped = Editor.snapshot(run.id)
    assert stopped.run.status == "interrupted"
    refute stopped.run.source_writer_pending
    assert stopped.run.source_writer_token == nil
    assert stopped.pending_questions == []
    assert :ok = Editor.source_write_settled(waiting.run.workspace)

    assert Enum.any?(stopped.events, fn event ->
             event.kind == "source_writer_settled" and
               event.payload["native_stop_confirmed"] == true and
               event.payload["operator_reconciled"] != true
           end)

    assert File.read!(Path.join(waiting.run.workspace, "priv/docs/before-shutdown.md")) ==
             "real owned source\n"

    refute File.exists?(Path.join(waiting.run.workspace, "priv/docs/after-shutdown.md"))
  end

  test "admission is bounded to two real active native sessions" do
    runs =
      for index <- 1..2 do
        task = "Hold editorial slot #{index}"

        script =
          expect_react do
            user(task)
            call("question", %{question: "Keep this slot occupied?"})
            answer("The slot was released.")
          end

        {:ok, run} = Editor.start_run(%{task: task}, react_opts(script))
        await_snapshot(run.id, &(&1.pending_questions != []))
        run
      end

    script =
      expect_react do
        user("A third editorial slot")
        answer("This must not be requested.")
      end

    assert {:error, :editor_capacity} =
             Editor.start_run(%{task: "A third editorial slot"}, react_opts(script))

    for run <- runs do
      assert :ok = Editor.cancel_run(run.id)
      await_snapshot(run.id, &(&1.run.status == "cancelled" and &1.session["status"] == "idle"))
    end
  end

  test "every real process launch waits for human approval, including read-only Git" do
    script =
      expect_react do
        user("Inspect source status")
        call("git", %{operation: "status"})
        answer("The Git status was inspected.")
      end

    {:ok, run} =
      Editor.start_run(%{task: "Inspect source status", mode: "docs"}, react_opts(script))

    first = await_snapshot(run.id, &(&1.pending_questions != []))

    assert [%{question: %{"kind" => "process", "effect" => %{"executable" => executable}}}] =
             first.pending_questions

    assert Path.basename(executable) == "git"
    approve_until_terminal(run.id)

    completed =
      await_snapshot(run.id, &(&1.run.status == "completed" and &1.session["status"] == "idle"))

    assert Enum.any?(
             completed.session["effects"],
             &(&1["name"] == "git" and &1["status"] == "completed")
           )
  end

  test "coding mode requires approval before a native shell can write source" do
    script =
      expect_react do
        user("Create a coding receipt")

        call("shell", %{
          executable: "sh",
          args: ["-c", "printf coding-approved > lib/receipt.txt"]
        })

        answer("The approved coding receipt was created.")
      end

    {:ok, run} =
      Editor.start_run(%{task: "Create a coding receipt", mode: "coding"}, react_opts(script))

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    refute File.exists?(Path.join(waiting.run.workspace, "lib/receipt.txt"))
    [%{id: question_id}] = waiting.pending_questions
    assert :ok = Editor.answer(run.id, question_id, "approve")
    complete = await_snapshot(run.id, &(&1.run.status == "completed"))
    assert File.read!(Path.join(complete.run.workspace, "lib/receipt.txt")) == "coding-approved"
  end

  test "denying a native process approval leaves the source untouched" do
    script =
      expect_react do
        user("Deny this coding process")
        call("shell", %{executable: "sh", args: ["-c", "printf forbidden > lib/denied.txt"]})
        answer("The process was not approved.")
      end

    {:ok, run} =
      Editor.start_run(%{task: "Deny this coding process", mode: "coding"}, react_opts(script))

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    [%{id: question_id}] = waiting.pending_questions
    assert :ok = Editor.answer(run.id, question_id, "deny")

    complete =
      await_snapshot(run.id, &(&1.run.status == "completed" and &1.session["status"] == "idle"))

    refute File.exists?(Path.join(complete.run.workspace, "lib/denied.txt"))
    checkpoint = native_checkpoint(complete.run)
    {_id, denied} = Enum.find(checkpoint.effects, fn {_id, effect} -> effect.name == "shell" end)
    assert denied.status == :completed
    assert {:error, %{details: %{reason: :approval_denied}}, _directives} = denied.result
  end

  test "cancelling an approved native process stops its owned work without replay" do
    script =
      expect_react do
        user("Start a cancellable coding process")

        call("shell", %{
          executable: "sh",
          args: [
            "-c",
            "printf started > priv/docs/process-started.md; sleep 30; printf forbidden > priv/docs/process-completed.md"
          ]
        })

        answer("The process finished.")
      end

    {:ok, run} =
      Editor.start_run(
        %{task: "Start a cancellable coding process", mode: "coding"},
        react_opts(script)
      )

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    [%{id: question_id}] = waiting.pending_questions
    assert :ok = Editor.answer(run.id, question_id, "approve")

    await_snapshot(
      run.id,
      &File.exists?(Path.join(&1.run.workspace, "priv/docs/process-started.md"))
    )

    assert :ok = Editor.cancel_run(run.id)

    cancelled =
      await_snapshot(run.id, &(&1.run.status == "cancelled" and &1.session["status"] == "idle"))

    refute File.exists?(Path.join(cancelled.run.workspace, "priv/docs/process-completed.md"))

    assert Enum.any?(
             cancelled.session["effects"],
             &(&1["name"] == "shell" and &1["status"] == "uncertain")
           )
  end

  test "docs mode rejects source-code edits, traversal, symlink escapes and arbitrary execution" do
    script =
      expect_react do
        user("Wait while host policy is inspected")
        call("question", %{question: "Ready?"})
        answer("Policy inspection finished.")
      end

    {:ok, run} =
      Editor.start_run(%{task: "Wait while host policy is inspected"}, react_opts(script))

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    session = %SessionRef{runtime: @runtime, id: waiting.run.session_id}

    File.ln_s!(
      Path.join(waiting.run.workspace, "lib/untouched.ex"),
      Path.join(waiting.run.workspace, "priv/docs/escape.md")
    )

    for path <- [
          "lib/untouched.ex",
          "priv/docs/../escaped.md",
          "priv/docs/escape.md",
          ".git/config"
        ] do
      assert {:error, _} =
               OhMyJido.execute_tool(session, "write", %{
                 path: path,
                 content: "forbidden",
                 snapshot: "missing"
               })
    end

    assert {:error, _reason} =
             OhMyJido.execute_tool(session, "write", %{
               path: "lib/untouched.ex",
               content: "forbidden",
               snapshot: OhMyJido.Files.snapshot("defmodule Untouched, do: nil\n"),
               oh_my_jido: %{workspace: "/", permissions: [:read, :edit, :exec]},
               context: %{metadata: %{docs_mode: "coding"}}
             })

    assert {:error, {:unknown_tool, "shell"}} =
             OhMyJido.execute_tool(session, "shell", %{executable: "true"})

    assert File.read!(Path.join(waiting.run.workspace, "lib/untouched.ex")) ==
             "defmodule Untouched, do: nil\n"

    assert :ok = Editor.cancel_run(run.id)
    cancelled = await_snapshot(run.id, &(&1.run.status == "cancelled"))
    assert cancelled.pending_questions == []
  end

  test "a complete native runtime restart restores context without replaying an applied edit" do
    script =
      expect_react do
        user("Write once then wait")

        call("write", %{
          path: "priv/docs/receipt.md",
          content: "written once\n",
          snapshot: "missing"
        })

        call("question", %{question: "Continue after the receipt?"})

        call("write", %{
          path: "priv/docs/replayed.md",
          content: "must not replay\n",
          snapshot: "missing"
        })

        answer("Finished")
      end

    {:ok, run} = Editor.start_run(%{task: "Write once then wait"}, react_opts(script))
    await_snapshot(run.id, &(&1.pending_questions != []))
    native = Process.whereis(@runtime)
    monitor = Process.monitor(native)

    assert :ok =
             Supervisor.terminate_child(
               OhMyJidoDocs.DataCase.private_workers_supervisor(),
               @runtime
             )

    assert_receive {:DOWN, ^monitor, :process, ^native, _}, 5_000

    assert {:ok, _native} =
             Supervisor.restart_child(
               OhMyJidoDocs.DataCase.private_workers_supervisor(),
               @runtime
             )

    interrupted = await_snapshot(run.id, &(&1.run.status == "interrupted"))
    assert interrupted.pending_questions == []

    assert File.read!(Path.join(interrupted.run.workspace, "priv/docs/receipt.md")) ==
             "written once\n"

    refute File.exists?(Path.join(interrupted.run.workspace, "priv/docs/replayed.md"))
    assert interrupted.run.source_writer_pending

    assert {:error, :workspace_busy} =
             Workspaces.with_workspace_lease(interrupted.run.workspace, fn ->
               Editor.source_write_settled(interrupted.run.workspace)
             end)

    assert {:error, :native_stop_unconfirmed} = Editor.resume_run(run.id)

    assert {:error, :writer_claim_mismatch} =
             Editor.reconcile_writer(run.id, Ecto.UUID.generate(), :orphan_resources_reconciled)

    assert :ok =
             Editor.reconcile_writer(
               run.id,
               interrupted.run.source_writer_token,
               :orphan_resources_reconciled
             )

    reconciled = Editor.snapshot(run.id)
    refute reconciled.run.source_writer_pending

    assert Enum.any?(reconciled.events, fn event ->
             event.kind == "source_writer_settled" and
               event.payload["operator_reconciled"] == true and
               event.payload["native_stop_confirmed"] == false and
               event.payload["restored_owner_stop_confirmed"] == true
           end)

    assert :ok = Editor.resume_run(run.id)
    ready = Editor.snapshot(run.id)
    assert ready.run.status == "ready"

    original_effects =
      Enum.filter(ready.session["effects"], &(&1["run"] == interrupted.run.native_run_id))

    assert [_, _] = original_effects
    assert Enum.count(original_effects, &(&1["name"] == "write")) == 1
    refute File.exists?(Path.join(interrupted.run.workspace, "priv/docs/replayed.md"))
    prior_checkpoint = native_checkpoint(ready.run)

    uncertain =
      Enum.find_value(prior_checkpoint.effects, fn {_id, effect} ->
        if effect.name == "question", do: effect
      end)

    assert %{
             status: :uncertain,
             execution_settlement: %{
               source: :operator,
               execution: :stopped,
               native_stop_confirmed: false
             }
           } = uncertain

    refute Map.has_key?(uncertain, :completed_at)
    refute Map.has_key?(uncertain, :result)

    secret = "synthetic-restored-editor-key"
    Application.put_env(:oh_my_jido_docs, :model_api_key, secret)

    continuation =
      expect_react do
        user("Continue from the restored receipt")

        call("question", %{question: "Use the restored receipt?"},
          id: "restored-receipt-question"
        )

        call("read", %{path: "priv/docs/receipt.md"}, id: "restored-receipt-read")

        call(
          "edit",
          %{
            path: "priv/docs/receipt.md",
            snapshot: OhMyJido.Files.snapshot("written once\n"),
            edits: [%{old: "written once", new: "edited after native restore"}]
          },
          id: "restored-receipt-edit"
        )

        answer("The restored native context read and edited the receipt.")
      end

    continuation = script_after_transcript(continuation, prior_checkpoint.conversation)

    assert {:ok, new_native_id} =
             Editor.steer_run(
               run.id,
               "Continue from the restored receipt",
               react_opts(continuation)
             )

    refute new_native_id == interrupted.run.native_run_id
    resumed = await_snapshot(run.id, &(&1.pending_questions != []))
    session = %SessionRef{runtime: @runtime, id: resumed.run.session_id}
    assert {:ok, context} = OhMyJido.Session.call(session, :context)
    refute Map.has_key?(context.metadata, :docs_run_id)
    refute Map.has_key?(context.metadata, :docs_mode)

    assert {:ok, [api_key: ^secret, auth_mode: :api_key]} =
             Host.credentials(context, "docs-site", [])

    assert {:error, :credentials_required} = Host.credentials(context, "foreign-account", [])

    for foreign <- [
          %{context | runtime: __MODULE__.ForeignRuntime},
          %{context | session_id: "foreign-native-session"},
          %{context | workspace: "/"},
          %{context | metadata: Map.put(context.metadata, :docs_run_id, Ecto.UUID.generate())},
          %{context | metadata: Map.put(context.metadata, "docs_run_id", Ecto.UUID.generate())},
          %{context | metadata: Map.put(context.metadata, :docs_mode, "coding")},
          %{context | metadata: Map.put(context.metadata, "docs_mode", "coding")}
        ] do
      assert {:error, :invalid_editor_context} =
               Host.authorize(foreign, :read, %{path: "priv/docs/receipt.md"}, [])
    end

    [%{id: question_id}] = resumed.pending_questions
    assert :ok = Editor.answer(run.id, question_id, "Use the restored receipt")

    completed =
      await_snapshot(run.id, &(&1.run.status == "completed" and &1.session["status"] == "idle"))

    assert File.read!(Path.join(completed.run.workspace, "priv/docs/receipt.md")) ==
             "edited after native restore\n"

    refute File.exists?(Path.join(completed.run.workspace, "priv/docs/replayed.md"))

    assert Enum.any?(
             completed.session["effects"],
             &(&1["run"] == new_native_id and &1["name"] == "read" and &1["status"] == "completed")
           )

    assert Enum.any?(
             completed.session["effects"],
             &(&1["run"] == new_native_id and &1["name"] == "edit" and &1["status"] == "completed")
           )

    retained_effects =
      Enum.filter(completed.session["effects"], &(&1["run"] == interrupted.run.native_run_id))

    assert Enum.sort_by(retained_effects, & &1["id"]) ==
             Enum.sort_by(original_effects, & &1["id"])
  end

  @tag capture_log: true
  test "operator settlement interrupts an active row before queued native DOWN is processed" do
    task = "Hold real work before the observer handles native loss"
    assert {:ok, run} = Editor.start_run(%{task: task}, react_opts(crash_script(task)))
    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    native_id = waiting.run.native_run_id
    claim = waiting.run.source_writer_token
    observer = Process.whereis(OhMyJidoDocs.Editor.Observer)

    assert {:ok, info} =
             OhMyJido.inspect_session(%SessionRef{runtime: @runtime, id: run.session_id})

    true = :erlang.suspend_process(observer)

    request =
      try do
        request =
          Task.async(fn ->
            Editor.reconcile_writer(run.id, claim, :orphan_resources_reconciled)
          end)

        assert await_native_value(fn -> queued_operator_call?(observer, run.id, claim) end)
        restart_native_runtime()
        refute Process.alive?(info.agent_pid)
        request
      after
        :erlang.resume_process(observer)
      end

    assert :ok = Task.await(request, 15_000)
    settled = await_snapshot(run.id, &(not &1.run.source_writer_pending))
    assert settled.run.status == "interrupted"
    assert settled.run.pending_questions == %{}
    assert settled.pending_questions == []
    assert_operator_writer_settled(settled, claim, native_id, waiting.run.last_seq)
    old_effects = assert_operator_effects(native_checkpoint(settled.run), native_id)
    resume_with_native_read(settled.run, native_id, old_effects)
  end

  @tag capture_log: true
  test "operator reconciliation recovers a first native turn accepted before its CMS ID persists" do
    prompt_acceptance_crash(:first)
  end

  @tag capture_log: true
  test "operator reconciliation replaces a preceding ready turn ID after a real prompt crash" do
    prompt_acceptance_crash(:previous)
  end

  @tag capture_log: true
  test "operator provenance survives observer death after the real native settlement import" do
    task = "Write a receipt before the operator import crash"
    assert {:ok, run} = Editor.start_run(%{task: task}, react_opts(crash_script(task)))
    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    native_id = waiting.run.native_run_id
    assert {:ok, original_holder} = WriterLease.lookup(Editor.get_run!(run.id))
    original_native_pid = original_holder.native_pid
    restart_native_runtime()
    refute Process.alive?(original_native_pid)

    interrupted =
      await_snapshot(run.id, &(&1.run.status == "interrupted" and &1.run.source_writer_pending))

    claim = interrupted.run.source_writer_token
    question = native_checkpoint(interrupted.run).effects["crash-pending-question"]
    assert question.run == native_id
    refute Map.has_key?(question, :execution_settlement)

    window =
      native_start_barrier(
        :reconcile_interrupted,
        fn ->
          request =
            Task.async(fn ->
              Editor.reconcile_writer(run.id, claim, :orphan_resources_reconciled)
            end)

          {interrupted.run, request}
        end,
        fn current ->
          assert current.source_writer_token == claim
          assert_operator_origin(current, nil)
        end
      )

    %{barrier: barrier, native_pid: temporary_pid, observer: observer} = window

    assert_receive {:native_call_paused, ^barrier, ^temporary_pid,
                    {:reconcile_interrupted, ^native_id, ["crash-pending-question"]}},
                   5_000

    assert_receive {:native_call_replied, ^barrier, ^temporary_pid, :ok}, 5_000
    assert Process.info(observer, :status) == {:status, :suspended}
    current = Editor.get_run!(run.id)
    assert current.source_writer_pending
    assert current.source_writer_token == claim
    assert_operator_origin(current, native_id)
    assert {:ok, temporary_holder} = WriterLease.lookup(current)
    assert temporary_holder.pid == original_holder.pid
    assert temporary_holder.native_pid == temporary_pid
    refute temporary_pid == original_native_pid
    assert {:ok, imported_info} = OhMyJido.inspect_session(window.session)
    imported_effects = assert_operator_effects(native_checkpoint(current), native_id)
    assert_crash_source(current.workspace)

    with_paused_editor_supervisor(fn ->
      kill_observer(observer)
      assert_crashed_request(window.request)
      assert Process.alive?(temporary_pid)
      assert Process.alive?(imported_info.agent_pid)
      assert Process.alive?(temporary_holder.pid)
      assert_operator_origin(Editor.get_run!(run.id), native_id)
      assert {:error, :workspace_busy} = Editor.source_write_settled(current.workspace)
    end)

    settled = await_snapshot(run.id, &(not &1.run.source_writer_pending))
    refute Process.alive?(temporary_pid)
    refute Process.alive?(imported_info.agent_pid)
    refute Process.whereis(OhMyJidoDocs.Editor.Observer) == observer
    assert_operator_writer_settled(settled, claim, native_id, interrupted.run.last_seq)
    assert effects_for(native_checkpoint(settled.run), native_id) == imported_effects
    resume_with_native_read(settled.run, native_id, imported_effects)
  end

  test "suspend, resume and cancel remain native controls rather than new model requests" do
    script =
      expect_react do
        user("Pause for the operator")
        call("question", %{question: "Proceed?"})
        answer("The operator answered.")
      end

    {:ok, run} = Editor.start_run(%{task: "Pause for the operator"}, react_opts(script))
    await_snapshot(run.id, &(&1.pending_questions != []))
    assert :ok = Editor.steer_run(run.id, "Preserve all existing source files")
    assert :ok = Editor.suspend_run(run.id)
    suspended = await_snapshot(run.id, &(&1.run.status == "suspended"))
    assert :ok = Editor.resume_run(run.id)
    assert Editor.snapshot(run.id).run.status == "ready"
    assert Editor.snapshot(run.id).pending_questions == []

    assert File.read!(Path.join(suspended.run.workspace, "priv/docs/index.md")) =~
             "A typo lives here."
  end

  test "credentials are explicit, account-bound, redacted and never sourced from request attributes" do
    assert {:error, :credentials_required} = Editor.start_run(%{task: "No provider access"})

    assert {:error, :invalid_run_attributes} =
             Editor.start_run(%{task: "Escalate", workspace: "/", account: "other"})

    assert {:error, :invalid_run_options} =
             Editor.start_run(%{task: "Escalate"}, host: {OhMyJido.Host.Local, []})

    assert {:error, :credentials_required} =
             Host.credentials(
               %OhMyJido.Context{
                 session_id: "test",
                 workspace: "/tmp",
                 permissions: MapSet.new()
               },
               "docs-site",
               []
             )

    secret = "synthetic-docs-key-never-persist"
    Application.put_env(:oh_my_jido_docs, :model_api_key, secret)

    script =
      expect_react do
        user("Redact host credentials")
        call("question", %{question: "Inspect the explicit host account?"})
        answer("Credential value: #{secret}")
      end

    {:ok, run} = Editor.start_run(%{task: "Redact host credentials"}, react_opts(script))

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    session = %SessionRef{runtime: @runtime, id: waiting.run.session_id}
    assert {:ok, context} = OhMyJido.Session.call(session, :context)

    assert {:ok, [api_key: ^secret, auth_mode: :api_key]} =
             Host.credentials(context, "docs-site", [])

    assert {:error, :credentials_required} = Host.credentials(context, "another-account", [])

    assert {:error, :credentials_required} =
             Host.credentials(%{context | coordinator: self()}, "docs-site", [])

    [%{id: question_id}] = waiting.pending_questions
    assert :ok = Editor.answer(run.id, question_id, "Account inspected")

    snapshot =
      await_snapshot(run.id, &(&1.run.status == "completed" and not &1.run.source_writer_pending))

    refute inspect(snapshot, limit: :infinity) =~ secret
    assert {:error, :credentials_required} = Host.credentials(context, "docs-site", [])
    checkpoint = native_checkpoint(snapshot.run)
    refute inspect(checkpoint, limit: :infinity) =~ secret

    {:ok, config} = Runtime.config(@runtime)

    Registry.put_meta(
      Runtime.registry(@runtime),
      :config,
      Keyword.put(config, :allow_test_scripts, false)
    )

    assert {:error, :test_scripts_not_enabled} =
             Editor.start_run(%{task: "Redact host credentials"}, react_opts(script))
  end

  test "a paused native writer fences real adoption across holder death and observer restart", %{
    root: root
  } do
    original = "# Guide\n\nA typo lives here.\n"
    reviewed = "# Guide\n\nA reviewed correction lives here.\n"

    initial =
      expect_react do
        user("Prepare the reviewed correction")

        call("edit", %{
          path: "priv/docs/index.md",
          snapshot: OhMyJido.Files.snapshot(original),
          edits: [%{old: "A typo lives here.", new: "A reviewed correction lives here."}]
        })

        call("question", %{question: "Retain this reviewed correction?"})
        answer("The reviewed correction was retained.")
      end

    assert {:ok, run} =
             Editor.start_run(
               %{task: "Prepare the reviewed correction", mode: "coding"},
               react_opts(initial)
             )

    await_snapshot(run.id, &(&1.pending_questions != []))
    assert :ok = Editor.suspend_run(run.id)
    await_snapshot(run.id, &(&1.run.status == "suspended" and not &1.run.source_writer_pending))
    assert :ok = Editor.resume_run(run.id)

    ready =
      await_snapshot(run.id, &(&1.run.status == "ready" and not &1.run.source_writer_pending))

    assert File.read!(Path.join(ready.run.workspace, "priv/docs/index.md")) == reviewed
    assert {:ok, frozen} = Workspaces.freeze(ready.run.workspace, "native-writer-#{run.id}")

    gate = Path.join(root, "native-write-gate")
    assert {_, 0} = System.cmd("mkfifo", [gate], stderr_to_stdout: true)

    command =
      "printf 'native-writer-paused\\n'; IFS= read -r proceed < #{shell_argument(gate)}; printf '# Unreviewed write\\n' > priv/docs/index.md"

    next =
      expect_react do
        user("Pause an explicitly approved native write")
        call("shell", %{executable: "sh", args: ["-c", command]}, id: "paused-native-writer")
        answer("This turn must be interrupted, not replayed.")
      end

    next = script_after_transcript(next, native_checkpoint(ready.run).conversation)

    assert {:ok, _native_run} =
             Editor.steer_run(
               run.id,
               "Pause an explicitly approved native write",
               react_opts(next)
             )

    approval = await_snapshot(run.id, &(&1.pending_questions != []))
    [%{id: approval_id}] = approval.pending_questions
    assert :ok = Editor.answer(run.id, approval_id, "approve")

    paused =
      await_snapshot(run.id, fn snapshot ->
        Enum.any?(snapshot.events, fn event ->
          event.kind == "tool_output" and
            String.contains?(Map.get(event.payload, "text", ""), "native-writer-paused")
        end)
      end)

    assert {:ok, holder} = WriterLease.lookup(Editor.get_run!(run.id))
    native_pid = holder.native_pid
    assert Process.alive?(native_pid)
    session = %SessionRef{runtime: @runtime, id: paused.run.session_id}
    assert {:ok, context} = OhMyJido.Session.call(session, :context)
    Application.put_env(:oh_my_jido_docs, :model_api_key, "synthetic-live-writer-key")
    assert {:ok, _credentials} = Host.credentials(context, "docs-site", [])
    assert {:error, :workspace_busy} = Workspaces.adopt(frozen)

    supervisor = OhMyJidoDocs.Editor.Supervisor
    observer = Process.whereis(OhMyJidoDocs.Editor.Observer)
    assert :ok = :sys.suspend(supervisor)

    try do
      assert :ok = :sys.suspend(observer)
      holder_monitor = Process.monitor(holder.pid)
      observer_monitor = Process.monitor(observer)
      Process.exit(holder.pid, :kill)
      assert_receive {:DOWN, ^holder_monitor, :process, _holder, :killed}, 5_000
      Process.exit(observer, :kill)
      assert_receive {:DOWN, ^observer_monitor, :process, ^observer, :killed}, 5_000
      assert Process.alive?(native_pid)
      assert Editor.get_run!(run.id).source_writer_pending

      assert {:error, :workspace_busy} =
               Workspaces.with_workspace_lease(paused.run.workspace, fn ->
                 assert Process.alive?(native_pid)

                 assert {:error, :workspace_busy} =
                          Editor.source_write_settled(paused.run.workspace)

                 Workspaces.adopt(frozen)
               end)

      assert {:error, :invalid_editor_context} =
               Host.authorize(context, :edit, %{path: "priv/docs/index.md"}, [])

      assert {:error, :credentials_required} = Host.credentials(context, "docs-site", [])
      assert File.read!(Path.join(paused.run.workspace, "priv/docs/index.md")) == reviewed
      refute File.exists?(Path.join(root, "data/source/current.json"))
    after
      :ok = :sys.resume(supervisor)
    end

    stopped =
      await_snapshot(
        run.id,
        &(&1.run.status == "interrupted" and not &1.run.source_writer_pending)
      )

    refute Process.alive?(native_pid)
    assert stopped.run.source_writer_token == nil

    assert Enum.any?(stopped.events, fn event ->
             event.kind == "source_writer_settled" and
               event.payload["native_stop_confirmed"] == true
           end)

    assert :ok = Workspaces.verify_workspace(stopped.run.workspace, frozen.workspace_digest)
    assert {:ok, adopted} = Workspaces.adopt(frozen)

    assert File.read!(Path.join(adopted["source_root"], "examples/docs_site/priv/docs/index.md")) ==
             reviewed

    assert File.read!(Path.join(stopped.run.workspace, "priv/docs/index.md")) == reviewed
  end

  test "source settlement denies an unavailable database instead of treating it as unmanaged" do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("unavailable-writer-state")

    assert :ok =
             Workspaces.with_workspace_lease(workspace, fn ->
               Editor.source_write_settled(workspace)
             end)

    result =
      Task.async(fn ->
        previous = Repo.get_dynamic_repo()
        Repo.put_dynamic_repo(__MODULE__.UnavailableRepo)

        try do
          Workspaces.with_workspace_lease(workspace, fn ->
            Editor.source_write_settled(workspace)
          end)
        after
          Repo.put_dynamic_repo(previous)
        end
      end)

    assert {:error, :writer_state_unavailable} = Task.await(result, 10_000)
    assert :ok = Editor.source_write_settled(workspace)
  end

  test "native output reaches durable, bounded event and session projections" do
    long_answer = String.duplicate("bounded output ", 10_000)

    script =
      expect_react do
        user("Return a long native answer")
        answer(long_answer)
      end

    {:ok, run} = Editor.start_run(%{task: "Return a long native answer"}, react_opts(script))

    snapshot =
      await_snapshot(run.id, &(&1.run.status == "completed" and &1.session["status"] == "idle"))

    assert Enum.count_until(snapshot.events, 257) <= 256
    assert byte_size(snapshot.run.summary) < 4_200
    assert Enum.all?(snapshot.events, &(byte_size(Jason.encode!(&1.payload)) < 80_000))
    assert byte_size(Jason.encode!(snapshot.session)) < 80_000
  end

  defp prompt_acceptance_crash(position) do
    ready = if position == :previous, do: preceding_ready_turn()
    previous_id = if ready, do: ready.run.native_run_id
    task = "Write a receipt before the CMS prompt association"
    script = crash_script(task)

    script =
      if ready,
        do: script_after_transcript(script, native_checkpoint(ready.run).conversation),
        else: script

    window =
      native_start_barrier(:prompt, fn -> launch_crashing_prompt(ready, task, script) end)

    %{barrier: barrier, native_pid: native_pid, observer: observer, run: run} = window
    assert_receive {:native_call_paused, ^barrier, ^native_pid, :prompt}, 5_000
    assert_receive {:native_call_replied, ^barrier, ^native_pid, {:ok, native_id}}, 5_000
    assert is_binary(native_id)
    refute native_id == previous_id
    assert Process.info(observer, :status) == {:status, :suspended}

    info =
      await_native_value(fn ->
        case OhMyJido.inspect_session(window.session) do
          {:ok, %{active_run: ^native_id, pending_questions: [_ | _]} = info} -> info
          _pending -> nil
        end
      end)

    current = Editor.get_run!(run.id)
    assert current.native_run_id == previous_id
    assert current.source_writer_pending
    assert is_binary(current.source_writer_token)
    assert current.source_writer_origin == nil
    assert info.effects["crash-receipt-write"].status == :completed
    question = info.effects["crash-pending-question"]
    assert question.run == native_id
    assert question.status == :running
    refute Map.has_key?(question, :result)
    refute Map.has_key?(question, :completed_at)
    refute Map.has_key?(question, :execution_settlement)
    assert native_checkpoint(current).effects[question.id] == question
    assert_crash_source(current.workspace)

    with_paused_editor_supervisor(fn ->
      kill_observer(observer)
      assert_crashed_request(window.request)
      restart_native_runtime()
      refute Process.alive?(native_pid)
      refute Process.alive?(info.agent_pid)
      assert Editor.get_run!(run.id).native_run_id == previous_id
    end)

    interrupted =
      await_snapshot(run.id, &(&1.run.status == "interrupted" and &1.run.source_writer_pending))

    assert interrupted.run.native_run_id == previous_id
    assert interrupted.run.source_writer_token == current.source_writer_token
    assert interrupted.run.source_writer_origin == nil
    assert interrupted.pending_questions == []
    assert {:error, :workspace_busy} = Editor.source_write_settled(current.workspace)
    assert {:error, :native_stop_unconfirmed} = Editor.resume_run(run.id)

    assert {:error, :writer_claim_mismatch} =
             Editor.reconcile_writer(run.id, Ecto.UUID.generate(), :orphan_resources_reconciled)

    assert :ok =
             Editor.reconcile_writer(
               run.id,
               current.source_writer_token,
               :orphan_resources_reconciled
             )

    settled = await_snapshot(run.id, &(not &1.run.source_writer_pending))

    assert_operator_writer_settled(
      settled,
      current.source_writer_token,
      native_id,
      interrupted.run.last_seq
    )

    old_effects = assert_operator_effects(native_checkpoint(settled.run), native_id)
    resume_with_native_read(settled.run, native_id, old_effects)
  end

  defp launch_crashing_prompt(nil, task, script) do
    assert {:ok, run} = Editor.start_run(%{task: task}, react_opts(script))
    {run, nil}
  end

  defp launch_crashing_prompt(ready, task, script) do
    request = Task.async(fn -> Editor.steer_run(ready.run.id, task, react_opts(script)) end)
    {ready.run, request}
  end

  defp preceding_ready_turn do
    script =
      expect_react do
        user("Establish a preceding ready native turn")

        call("question", %{question: "Suspend this preceding turn?"},
          id: "preceding-ready-question"
        )

        answer("This preceding request is explicitly suspended.")
      end

    assert {:ok, run} =
             Editor.start_run(
               %{task: "Establish a preceding ready native turn"},
               react_opts(script)
             )

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    assert is_binary(waiting.run.native_run_id)
    assert :ok = Editor.suspend_run(run.id)
    await_snapshot(run.id, &(&1.run.status == "suspended" and not &1.run.source_writer_pending))
    assert :ok = Editor.resume_run(run.id)

    ready =
      await_snapshot(run.id, &(&1.run.status == "ready" and not &1.run.source_writer_pending))

    assert ready.run.native_run_id == waiting.run.native_run_id
    ready
  end

  defp crash_script(task) do
    expect_react do
      user(task)

      call(
        "write",
        %{
          path: "priv/docs/crash-receipt.md",
          content: "written before the crash\n",
          snapshot: "missing"
        },
        id: "crash-receipt-write"
      )

      call("question", %{question: "Keep this real effect pending?"},
        id: "crash-pending-question"
      )

      call("write", %{
        path: "priv/docs/crash-replayed.md",
        content: "this continuation must never execute\n",
        snapshot: "missing"
      })

      answer("The interrupted request must not be replayed.")
    end
  end

  defp assert_crash_source(workspace) do
    assert File.read!(Path.join(workspace, "priv/docs/crash-receipt.md")) ==
             "written before the crash\n"

    refute File.exists?(Path.join(workspace, "priv/docs/crash-replayed.md"))
  end

  defp assert_operator_origin(run, native_id) do
    digest = :crypto.hash(:sha256, run.source_writer_token) |> Base.encode16(case: :lower)

    assert run.source_writer_origin == %{
             "source" => "operator",
             "claim_digest" => digest,
             "session_id" => run.session_id,
             "workspace" => run.workspace,
             "native_run_id" => native_id
           }
  end

  defp assert_operator_effects(checkpoint, native_id) do
    effects = effects_for(checkpoint, native_id)
    assert map_size(effects) == 2
    assert effects["crash-receipt-write"].status == :completed
    assert checkpoint.runs[native_id].status == :interrupted

    assert %{
             status: :uncertain,
             execution_settlement: %{
               source: :operator,
               execution: :stopped,
               effect: :uncertain,
               native_stop_confirmed: false
             }
           } = effects["crash-pending-question"]

    refute Map.has_key?(effects["crash-pending-question"], :result)
    refute Map.has_key?(effects["crash-pending-question"], :completed_at)
    effects
  end

  defp assert_operator_writer_settled(snapshot, claim, native_id, after_seq) do
    assert snapshot.run.status == "interrupted"
    assert snapshot.run.native_run_id == native_id
    refute snapshot.run.source_writer_pending
    assert snapshot.run.source_writer_token == nil
    assert snapshot.run.source_writer_origin == nil
    session = %SessionRef{runtime: @runtime, id: snapshot.run.session_id}
    assert is_nil(GenServer.whereis(Runtime.via(session)))
    assert :ok = Editor.source_write_settled(snapshot.run.workspace)

    assert [settlement] =
             Enum.filter(
               snapshot.events,
               &(&1.kind == "source_writer_settled" and &1.seq > after_seq)
             )

    assert settlement.payload["operator_reconciled"] == true
    assert settlement.payload["native_stop_confirmed"] == false
    assert settlement.payload["restored_owner_stop_confirmed"] == true
    payloads = Jason.encode!(Enum.map(snapshot.events, & &1.payload))
    refute payloads =~ claim
    refute payloads =~ "source_writer_origin"
    refute payloads =~ "#PID<"

    assert {:error, :writer_claim_mismatch} =
             Editor.reconcile_writer(snapshot.run.id, claim, :orphan_resources_reconciled)
  end

  defp resume_with_native_read(run, interrupted_id, old_effects) do
    assert :ok = Editor.resume_run(run.id)

    ready =
      await_snapshot(run.id, &(&1.run.status == "ready" and not &1.run.source_writer_pending))

    assert ready.run.source_writer_origin == nil
    checkpoint = native_checkpoint(ready.run)
    assert effects_for(checkpoint, interrupted_id) == old_effects

    script =
      expect_react do
        user("Read the durable crash receipt in a new native turn")
        call("read", %{path: "priv/docs/crash-receipt.md"}, id: "post-crash-native-read")
        answer("The new native turn read the durable crash receipt.")
      end

    script = script_after_transcript(script, checkpoint.conversation)

    assert {:ok, new_native_id} =
             Editor.steer_run(
               run.id,
               "Read the durable crash receipt in a new native turn",
               react_opts(script)
             )

    refute new_native_id == interrupted_id

    completed =
      await_snapshot(run.id, fn snapshot ->
        snapshot.run.status == "completed" and not snapshot.run.source_writer_pending and
          snapshot.session["status"] == "idle"
      end)

    assert completed.run.native_run_id == new_native_id
    assert completed.run.source_writer_token == nil
    assert completed.run.source_writer_origin == nil
    assert :ok = Editor.source_write_settled(completed.run.workspace)
    assert_crash_source(completed.run.workspace)
    final_checkpoint = native_checkpoint(completed.run)
    assert effects_for(final_checkpoint, interrupted_id) == old_effects
    assert final_checkpoint.runs[new_native_id].status == :completed
    assert [read] = Map.values(effects_for(final_checkpoint, new_native_id))
    assert read.name == "read"
    assert read.status == :completed
    assert is_integer(read.completed_at)

    assert {:ok, %{content: "written before the crash\n", snapshot: snapshot}, []} = read.result
    assert snapshot == OhMyJido.Files.snapshot("written before the crash\n")

    assert Enum.any?(completed.session["effects"], fn effect ->
             effect["run"] == new_native_id and effect["name"] == "read" and
               effect["status"] == "completed"
           end)

    assert [settlement] =
             Enum.filter(
               completed.events,
               &(&1.kind == "source_writer_settled" and &1.seq > ready.run.last_seq)
             )

    assert settlement.payload["native_stop_confirmed"] == true
    refute settlement.payload["operator_reconciled"] == true
    refute settlement.payload["restored_owner_stop_confirmed"] == true
  end

  defp effects_for(checkpoint, native_id),
    do: Map.filter(checkpoint.effects, fn {_id, effect} -> effect.run == native_id end)

  defp native_start_barrier(operation, launch, before_init \\ fn _run -> :ok end) do
    observer = Process.whereis(OhMyJidoDocs.Editor.Observer)
    {barrier, debug} = native_call_barrier(observer, operation)
    agent_supervisor = Process.whereis(Jido.agent_supervisor_name(Runtime.engine(@runtime)))
    assert :ok = :sys.suspend(agent_supervisor)
    on_exit(fn -> resume_system_process(agent_supervisor) end)

    {run, request, session, native_pid, installer} =
      try do
        {run, request} = launch.()
        session = %SessionRef{runtime: @runtime, id: run.session_id}
        native_pid = await_native_value(fn -> GenServer.whereis(Runtime.via(session)) end)

        on_exit(fn ->
          resume_system_process(agent_supervisor)
          release_native_barrier(native_pid, observer)
        end)

        installer = Task.async(fn -> :sys.install(native_pid, debug) end)

        assert await_native_value(fn -> queued_system_install?(native_pid, installer) end)

        before_init.(Editor.get_run!(run.id))
        {run, request, session, native_pid, installer}
      after
        resume_system_process(agent_supervisor)
      end

    assert :ok = Task.await(installer, 5_000)

    %{
      run: run,
      request: request,
      session: session,
      native_pid: native_pid,
      observer: observer,
      barrier: barrier
    }
  end

  defp queued_operator_call?(observer, id, claim) do
    case Process.info(observer, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", _from, {:reconcile_writer, ^id, ^claim}} -> true
          _message -> false
        end)

      _unavailable ->
        false
    end
  end

  defp queued_system_install?(native_pid, installer) do
    case Process.info(native_pid, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:system, {pid, _tag}, {:debug, {:install, _spec}}} -> pid == installer.pid
          _message -> false
        end)

      _unavailable ->
        false
    end
  end

  defp native_call_barrier(observer, operation) do
    owner = self()
    barrier = make_ref()

    debug = fn
      :armed, {:in, {:"$gen_call", from, {^operation, _value, _options} = request}}, _name ->
        true = :erlang.suspend_process(observer)

        identity =
          case request do
            {:prompt, _query, _opts} -> :prompt
            {:reconcile_interrupted, run_id, ids} -> {:reconcile_interrupted, run_id, ids}
          end

        send(owner, {:native_call_paused, barrier, self(), identity})
        {:awaiting_reply, from}

      {:awaiting_reply, expected}, {:out, reply, from, _private_state}, _name
      when from == expected ->
        send(owner, {:native_call_replied, barrier, self(), reply})
        :done

      state, _event, _name ->
        state
    end

    # Explicit identity keeps sys from mistaking the tuple state for an install spec.
    {barrier, {barrier, debug, :armed}}
  end

  defp release_native_barrier(native_pid, observer) do
    if Process.alive?(native_pid) and Process.alive?(observer) do
      # Only the real Session can release its own Observer suspend count.
      :ok = :sys.install(native_pid, {&resume_suspended_observer/3, observer})
      OhMyJido.Session.call(native_pid, :inspect, 5_000)
    end
  catch
    :exit, _reason -> :ok
  end

  defp resume_suspended_observer(observer, _event, _name) do
    try do
      :erlang.resume_process(observer)
    catch
      :error, :badarg -> :ok
    end

    :done
  end

  defp with_paused_editor_supervisor(fun) do
    supervisor = Process.whereis(OhMyJidoDocs.Editor.Supervisor)
    assert :ok = :sys.suspend(supervisor)
    on_exit(fn -> resume_system_process(supervisor) end)

    try do
      fun.()
    after
      resume_system_process(supervisor)
    end
  end

  defp resume_system_process(pid) do
    if Process.alive?(pid), do: :sys.resume(pid), else: :ok
  catch
    :exit, _reason -> :ok
  end

  defp kill_observer(observer) do
    monitor = Process.monitor(observer)
    Process.exit(observer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^observer, :killed}, 5_000
  end

  defp assert_crashed_request(nil), do: :ok

  defp assert_crashed_request(request) do
    assert {:error, :editor_unavailable} = Task.await(request, 5_000)
  end

  defp restart_native_runtime do
    supervisor = OhMyJidoDocs.DataCase.private_workers_supervisor()
    native = Process.whereis(@runtime)
    monitor = Process.monitor(native)
    assert :ok = Supervisor.terminate_child(supervisor, @runtime)
    assert_receive {:DOWN, ^monitor, :process, ^native, _reason}, 5_000
    assert {:ok, _native} = Supervisor.restart_child(supervisor, @runtime)
  end

  defp await_native_value(fetch) do
    wait_native_value(fetch, System.monotonic_time(:millisecond) + 10_000)
  end

  defp wait_native_value(fetch, deadline) do
    case fetch.() do
      value when value not in [nil, false] ->
        value

      _pending ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: flunk("native crash barrier did not reach its expected state")

        receive do
        after
          25 -> :ok
        end

        wait_native_value(fetch, deadline)
    end
  end

  defp approve_until_terminal(id) do
    snapshot =
      await_snapshot(
        id,
        &(&1.pending_questions != [] or &1.run.status in ["completed", "failed", "cancelled"])
      )

    if snapshot.run.status in ["completed", "failed", "cancelled"] do
      snapshot
    else
      Enum.each(snapshot.pending_questions, fn %{id: question_id} ->
        assert :ok = Editor.answer(id, question_id, "approve")
      end)

      approve_until_terminal(id)
    end
  end

  defp await_snapshot(id, predicate) do
    wait_snapshot(id, predicate, System.monotonic_time(:millisecond) + 10_000)
  end

  defp wait_snapshot(id, predicate, deadline) do
    snapshot = Editor.snapshot(id)

    cond do
      predicate.(snapshot) ->
        snapshot

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("native editor did not reach expected state: #{inspect(snapshot)}")

      true ->
        receive do
          {:docs_run_updated, ^id} -> :ok
        after
          25 -> :ok
        end

        wait_snapshot(id, predicate, deadline)
    end
  end

  defp queued_cancel(restart_observer?) do
    data = Application.fetch_env!(:oh_my_jido_docs, :data_dir)
    lock = {{OhMyJidoDocs.Workspaces, data}, self()}
    assert :global.set_lock(lock, [node()], 0)

    script =
      expect_react do
        user("Cancel while source preparation is queued")
        answer("This native request must never start.")
      end

    run =
      try do
        {:ok, run} =
          Editor.start_run(
            %{task: "Cancel while source preparation is queued"},
            react_opts(script)
          )

        [creator] = Task.Supervisor.children(OhMyJidoDocs.Editor.Tasks)
        assert :ok = Editor.cancel_run(run.id)
        assert Editor.get_run!(run.id).workspace_cleanup_pending
        assert Process.alive?(creator)

        if restart_observer? do
          observer = Process.whereis(OhMyJidoDocs.Editor.Observer)
          monitor = Process.monitor(observer)
          Process.exit(observer, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^observer, _}, 5_000

          await_snapshot(run.id, fn _snapshot ->
            replacement = Process.whereis(OhMyJidoDocs.Editor.Observer)
            is_pid(replacement) and replacement != observer
          end)

          state = :sys.get_state(OhMyJidoDocs.Editor.Observer)
          assert creator in Map.values(state.orphans)
          assert state.tasks == %{}
        end

        run
      after
        :global.del_lock(lock, [node()])
      end

    snapshot = await_snapshot(run.id, &(not &1.run.workspace_cleanup_pending))
    assert snapshot.run.status == "cancelled"
    assert snapshot.run.native_run_id == nil
    refute Enum.any?(snapshot.events, &(&1.kind == "run_started"))
    assert Enum.any?(snapshot.events, &(&1.kind == "workspace_discarded"))
    assert {:error, :not_found} = OhMyJidoDocs.Workspaces.fetch(run.id)
    assert File.ls!(Path.join(data, "workspaces")) == []
    assert File.ls!(Path.join(data, "workspace_metadata")) == []
    assert OhMyJido.list_sessions(@runtime) == []
  end

  defp shell_argument(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp native_checkpoint(run) do
    {:ok, config} = Runtime.config(@runtime)

    assert {:ok, checkpoint, _condition} =
             OhMyJido.Persistence.read_session(config[:storage], {@runtime, run.session_id})

    checkpoint
  end

  defp script_after_transcript(script, conversation) do
    prefix =
      Enum.flat_map(conversation, fn message ->
        calls = native_field(message, :tool_calls, [])

        if native_field(message, :role) in [:assistant, "assistant"] and is_list(calls) and
             calls != [] do
          [%{type: :tool_call, tool_calls: Enum.map(calls, &scripted_call/1)}]
        else
          []
        end
      end)

    %{script | turns: prefix ++ script.turns}
  end

  defp scripted_call(call) do
    function = native_field(call, :function, %{})
    arguments = native_field(call, :arguments, native_field(function, :arguments, %{}))
    arguments = if is_binary(arguments), do: Jason.decode!(arguments), else: arguments

    %{
      id: native_field(call, :id),
      name: native_field(call, :name, native_field(function, :name)),
      arguments: arguments
    }
  end

  defp native_field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp git!(root, args) do
    File.mkdir_p!(root)
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
  end
end
