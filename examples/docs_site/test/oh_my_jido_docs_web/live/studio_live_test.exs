defmodule OhMyJidoDocsWeb.StudioLiveTest do
  use OhMyJidoDocsWeb.ConnCase, async: false

  import Jido.AI.Test
  import OhMyJidoDocsWeb.EditorialFixtures
  import Phoenix.LiveViewTest

  alias OhMyJidoDocs.{Candidates, Editor, Workspaces}

  @moduletag timeout: 60_000

  setup do
    configure_operator()
    fixture = source_fixture()
    scripted_runtime(fixture.root)
    fixture
  end

  test "native questions, source effects, escaped output and durable reconnect work through LiveView",
       %{conn: conn} do
    task = "Repair source <img id=request-xss src=x onerror=alert(1)>"

    script =
      expect_react do
        user(task)

        call("question", %{
          question: "Use <img id=question-xss src=x onerror=alert(1)>?",
          options: []
        })

        call("write", %{
          path: "priv/docs/answer.md",
          content: "# Answered through Studio\n",
          snapshot: "missing"
        })

        answer("<script id=answer-xss>alert('summary')</script>")
      end

    assert {:ok, run} = Editor.start_run(%{task: task, mode: "docs"}, react_opts(script))
    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    [%{id: question_id}] = waiting.pending_questions
    conn = sign_in(conn)
    assert {:ok, view, html} = live(conn, ~p"/studio/runs/#{run.id}")
    document = LazyHTML.from_document(html)
    assert Enum.empty?(LazyHTML.query(document, "#run-task img, #pending-questions img"))
    assert LazyHTML.query(document, "#run-task") |> LazyHTML.text() == task

    render_submit(view, "answer", %{
      "question_id" => "not-a-pending-question",
      "answer" => "approve"
    })

    assert Editor.snapshot(run.id).pending_questions == waiting.pending_questions
    refute File.exists?(Path.join(waiting.run.workspace, "priv/docs/answer.md"))

    view
    |> form("#answer-#{question_id}", %{"answer" => "Use the reviewed answer"})
    |> render_submit()

    completed =
      await_snapshot(run.id, &(&1.run.status == "completed" and is_binary(&1.run.summary)))

    await_studio(view, &has_element?(&1, "#run-status[data-state=completed]"))

    assert File.read!(Path.join(completed.run.workspace, "priv/docs/answer.md")) ==
             "# Answered through Studio\n"

    assert Enum.any?(completed.events, &(&1.kind == "approval_answered"))
    GenServer.stop(view.pid)

    assert {:ok, reconnected, html} = live(conn, ~p"/studio/runs/#{run.id}")
    assert has_element?(reconnected, "#run-status[data-state=completed]")
    assert has_element?(reconnected, "#run-events article")
    document = LazyHTML.from_document(html)
    assert Enum.empty?(LazyHTML.query(document, "#run-summary script, #run-events script"))
    assert LazyHTML.query(document, "#run-summary") |> LazyHTML.text() == completed.run.summary
  end

  test "explicit process approval executes only the host's native pending effect", %{conn: conn} do
    task = "Approve the scoped source write"

    script =
      expect_react do
        user(task)

        call("shell", %{
          executable: "sh",
          args: ["-c", "printf approved-in-studio > lib/approved.txt"]
        })

        answer("The approved source effect finished.")
      end

    {:ok, run} = Editor.start_run(%{task: task, mode: "coding"}, react_opts(script))
    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    [%{id: question_id, question: %{"kind" => "process"}}] = waiting.pending_questions
    refute File.exists?(Path.join(waiting.run.workspace, "lib/approved.txt"))
    {:ok, view, _html} = live(sign_in(conn), ~p"/studio/runs/#{run.id}")

    render_click(view, "approve_effect", %{
      "question_id" => question_id,
      "run_id" => Ecto.UUID.generate(),
      "effect" => %{"executable" => "untrusted-form-command", "args" => ["must-not-be-used"]}
    })

    completed =
      await_snapshot(run.id, &(&1.run.status == "completed" and &1.session["status"] == "idle"))

    await_studio(view, &has_element?(&1, "#run-status[data-state=completed]"))

    assert File.read!(Path.join(completed.run.workspace, "lib/approved.txt")) ==
             "approved-in-studio"

    assert Enum.any?(
             completed.session["effects"],
             &(&1["name"] == "shell" and &1["status"] == "completed")
           )
  end

  test "process denial leaves the actual source unchanged", %{conn: conn} do
    script =
      expect_react do
        user("Deny a source process")
        call("shell", %{executable: "sh", args: ["-c", "printf denied > lib/denied.txt"]})
        answer("The operator denied the process.")
      end

    {:ok, run} =
      Editor.start_run(%{task: "Deny a source process", mode: "coding"}, react_opts(script))

    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    [%{id: question_id}] = waiting.pending_questions
    {:ok, view, _html} = live(sign_in(conn), ~p"/studio/runs/#{run.id}")
    view |> element("#deny-effect-#{question_id}") |> render_click()

    completed =
      await_snapshot(run.id, &(&1.run.status == "completed" and &1.session["status"] == "idle"))

    await_studio(view, &has_element?(&1, "#run-status[data-state=completed]"))

    refute File.exists?(Path.join(completed.run.workspace, "lib/denied.txt"))
  end

  test "steering, suspend, checkpoint resume and cancellation are real native controls", %{
    conn: conn
  } do
    script =
      expect_react do
        user("Pause source work in Studio")
        call("question", %{question: "Proceed with the source effect?"})

        call("write", %{
          path: "priv/docs/must-not-replay.md",
          content: "not yet approved\n",
          snapshot: "missing"
        })

        answer("Finished")
      end

    {:ok, run} = Editor.start_run(%{task: "Pause source work in Studio"}, react_opts(script))
    await_snapshot(run.id, &(&1.pending_questions != []))
    conn = sign_in(conn)
    {:ok, view, _html} = live(conn, ~p"/studio/runs/#{run.id}")
    view |> form("#steer-run", steer: %{text: "Preserve every existing file"}) |> render_submit()

    await_snapshot(run.id, fn snapshot ->
      Enum.any?(
        snapshot.events,
        &(&1.kind == "steering_queued" and &1.payload["text"] == "Preserve every existing file")
      )
    end)

    await_studio(view, &has_element?(&1, "#run-events [data-kind=steering_queued]"))

    view |> element("#suspend-run") |> render_click()
    suspended = await_snapshot(run.id, &(&1.run.status == "suspended"))
    await_studio(view, &has_element?(&1, "#run-status[data-state=suspended]"))
    view |> element("#resume-run") |> render_click()
    resumed = await_snapshot(run.id, &(&1.run.status == "ready"))
    await_studio(view, &has_element?(&1, "#run-status[data-state=ready]"))
    assert resumed.run.native_run_id == suspended.run.native_run_id
    assert resumed.pending_questions == []
    refute File.exists?(Path.join(resumed.run.workspace, "priv/docs/must-not-replay.md"))
    GenServer.stop(view.pid)

    {:ok, next} = Editor.start_run(%{task: "Pause source work in Studio"}, react_opts(script))
    await_snapshot(next.id, &(&1.pending_questions != []))
    {:ok, next_view, _html} = live(conn, ~p"/studio/runs/#{next.id}")
    next_view |> element("#cancel-run") |> render_click()
    cancelled = await_snapshot(next.id, &(&1.run.status == "cancelled"))
    await_studio(next_view, &has_element?(&1, "#run-status[data-state=cancelled]"))
    assert cancelled.pending_questions == []
    refute File.exists?(Path.join(cancelled.run.workspace, "priv/docs/must-not-replay.md"))
  end

  test "browser params cannot become host model options or grant credentials", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn), ~p"/studio")

    render_submit(view, "start_run", %{
      "run" => %{
        "task" => "Do not use browser credentials",
        "mode" => "docs",
        "model_api_key" => "untrusted-browser-secret",
        "allow_test_scripts" => true,
        "react_opts" => %{"script" => []},
        "workspace" => "/tmp/browser-selected-path"
      }
    })

    await_studio(view, &has_element?(&1, "#flash-error"))
    assert Editor.list_runs() == []
    assert has_element?(view, "#flash-error")
  end

  test "credential rotation blocks an already-connected socket before a native mutation", %{
    conn: conn
  } do
    script =
      expect_react do
        user("Wait for an authorized operator")
        call("question", %{question: "Continue?"})
        answer("Done")
      end

    {:ok, run} = Editor.start_run(%{task: "Wait for an authorized operator"}, react_opts(script))
    waiting = await_snapshot(run.id, &(&1.pending_questions != []))
    {:ok, view, _html} = live(sign_in(conn), ~p"/studio/runs/#{run.id}")

    Application.put_env(
      :oh_my_jido_docs,
      :operator_password_hash,
      Pbkdf2.hash_pwd_salt("rotated", rounds: 4)
    )

    render_click(view, "cancel", %{})
    assert_redirect(view, ~p"/login")
    current = Editor.snapshot(run.id)
    assert current.run.status == waiting.run.status
    assert current.pending_questions == waiting.pending_questions
  end

  test "credential rotation rejects an idle socket's live patch before loading a private diff", %{
    conn: conn
  } do
    id = Ecto.UUID.generate()
    {:ok, workspace} = Workspaces.create(id)

    run =
      stored_run(%{
        id: id,
        workspace: workspace.workspace,
        base_revision: workspace.base_revision
      })

    File.write!(
      Path.join(run.workspace, "priv/docs/index.md"),
      "# Private candidate\n\nMust not reach a rotated socket.\n"
    )

    {:ok, candidate} = Candidates.prepare(run.id)
    {:ok, view, _html} = live(sign_in(conn), ~p"/studio")

    Application.put_env(
      :oh_my_jido_docs,
      :operator_password_hash,
      Pbkdf2.hash_pwd_salt("rotated-before-patch", rounds: 4)
    )

    render_patch(view, ~p"/studio/runs/#{run.id}/candidates/#{candidate.id}")
    assert_redirect(view, ~p"/login")
    assert Candidates.get!(candidate.id).approval_digest == nil
  end

  test "credential rotation gates an in-flight host action's async completion", %{conn: conn} do
    {:ok, view, _html} = live(sign_in(conn), ~p"/studio")
    observer = OhMyJidoDocs.Editor.Observer
    :ok = :sys.suspend(observer)

    try do
      render_submit(view, "start_run", %{
        "run" => %{
          "task" => "A real host request with no configured credentials",
          "mode" => "docs"
        }
      })

      assert has_element?(view, "#host-action")

      Application.put_env(
        :oh_my_jido_docs,
        :operator_password_hash,
        Pbkdf2.hash_pwd_salt("rotated-before-async", rounds: 4)
      )

      :ok = :sys.resume(observer)
      assert_redirect(view, ~p"/login", 5000)
      assert Editor.list_runs() == []
    after
      :sys.resume(observer)
    end
  end

  test "candidate review escapes actual diffs and rejects client-authored digest and approval authority",
       %{conn: conn} do
    id = Ecto.UUID.generate()
    {:ok, workspace} = Workspaces.create(id)

    run =
      stored_run(%{
        id: id,
        workspace: workspace.workspace,
        base_revision: workspace.base_revision
      })

    File.write!(
      Path.join(run.workspace, "priv/docs/index.md"),
      "# Edited source\n\n<script id=diff-xss>not executed</script>\n"
    )

    {:ok, candidate} = Candidates.prepare(run.id)
    {:ok, view, html} = live(sign_in(conn), ~p"/studio/runs/#{run.id}/candidates/#{candidate.id}")
    document = LazyHTML.from_document(html)
    assert Enum.empty?(LazyHTML.query(document, "#source-diff script"))
    assert LazyHTML.query(document, "#source-diff") |> LazyHTML.text() =~ "<script id=diff-xss>"

    render_click(view, "approve_candidate", %{
      "candidate_id" => Ecto.UUID.generate(),
      "digest" => String.duplicate("f", 64),
      "check_status" => "passed",
      "approval_digest" => candidate.digest
    })

    await_studio(view, &has_element?(&1, "#flash-error"))
    current = Candidates.get!(candidate.id)
    assert current.approval_digest == nil
    assert current.check_status == "pending"
    assert current.digest == candidate.digest
    assert has_element?(view, "#flash-error")

    render_click(view, "publish_candidate", %{
      "digest" => candidate.digest,
      "approval_digest" => candidate.digest
    })

    await_studio(view)
    assert Candidates.get!(candidate.id).publication_digest == nil
  end
end
