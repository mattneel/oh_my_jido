defmodule OhMyJidoDocs.CandidatesTest do
  use OhMyJidoDocs.DataCase, async: false
  import OhMyJidoDocs.CandidateFixtures

  alias OhMyJidoDocs.{Candidates, Content, Editor, Workspaces}
  alias OhMyJidoDocs.Candidates.Runner

  @moduletag :candidate_integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  setup %{tmp_dir: temporary} do
    {:ok, setup_fixture(temporary)}
  end

  test "real child tests and production release bind review and docs publication to exact source",
       context do
    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "priv/docs/index.md"), "# Reviewed\n\nExact source bytes.\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    assert candidate.diff =~ "+Exact source bytes."
    assert {:error, :checks_required} = Candidates.approve(candidate.id, candidate.digest)
    assert {:error, :stale_digest} = Candidates.approve(candidate.id, String.duplicate("0", 64))
    assert false == :code.is_loaded(CandidateOnly.Authored)

    checked = check!(candidate)
    assert checked.check_digest == candidate.digest

    assert Enum.any?(
             checked.check_receipt["steps"],
             &(&1["args"] == ["test"] and &1["exit_status"] == 0)
           )

    assert File.regular?(checked.check_receipt["release"])
    assert checked.check_receipt["context"]["source"] != context.source

    assert File.read!(
             Path.join(checked.check_receipt["context"]["source"], "lib/candidate_library.ex")
           ) =~ "root-library"

    assert false == :code.is_loaded(CandidateOnly.Authored)
    assert {:error, :approval_required} = Candidates.publish(candidate.id, candidate.digest)
    assert {:ok, approved} = Candidates.approve(candidate.id, candidate.digest)
    assert approved.approval_digest == candidate.digest
    assert {:ok, published} = Candidates.publish(candidate.id, candidate.digest)
    assert published.publication_receipt["candidate_digest"] == candidate.digest
    assert {:ok, %{body: "# Reviewed\n\nExact source bytes.\n"}} = Content.get_page("index")
    assert false == :code.is_loaded(CandidateOnly.Authored)
    assert published.adoption_status == "adopted"
    assert {:ok, %{workspace: next_workspace}} = Workspaces.create(Ecto.UUID.generate())

    assert File.read!(Path.join(next_workspace, "priv/docs/index.md")) ==
             "# Reviewed\n\nExact source bytes.\n"

    rechecked = check!(published)
    assert {:ok, _} = Candidates.approve(rechecked.id, rechecked.digest)
    assert {:error, :deployment_unconfigured} = Candidates.deploy(rechecked.id, rechecked.digest)
  end

  test "publication reauthorizes after waiting on Content's real commit lock", context do
    {run, workspace} = run_workspace()
    docs = Path.join(workspace, "priv/docs/index.md")
    write!(docs, "# Reviewed before Content wait\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    candidate = check!(candidate)
    assert {:ok, _} = Candidates.approve(candidate.id, candidate.digest)
    previous_digest = Content.current_digest()
    lock = {{Content, Application.fetch_env!(:oh_my_jido_docs, :published_root)}, self()}
    assert :global.set_lock(lock, [node()])
    publication = Task.async(fn -> Candidates.publish(candidate.id, candidate.digest) end)

    try do
      waiting = await(candidate.id, &(&1.status == "publishing"))
      assert waiting.adoption_status == "adopted"
      assert Task.yield(publication, 20) == nil
      assert Content.current_digest() == previous_digest
      write!(docs, "# Unreviewed edit while Content was locked\n")
      :global.del_lock(lock, [node()])

      assert {:error, :workspace_changed} = Task.await(publication, 30_000)
      assert Content.current_digest() == previous_digest
      assert {:ok, %{body: "# Initial\n\nPublished source.\n"}} = Content.get_page("index")
      failed = Candidates.get!(candidate.id)
      assert failed.adoption_status == "adopted"
      assert failed.publication_receipt["status"] == "failed"
      assert failed.publication_receipt["source_remains_adopted"]
      assert failed.publication_receipt["reason"] =~ "workspace_changed"

      assert File.read!(Path.join(context.app, "priv/docs/index.md")) ==
               "# Initial\n\nPublished source.\n"

      assert {:ok, %{workspace: next}} = Workspaces.create(Ecto.UUID.generate())

      assert File.read!(Path.join(next, "priv/docs/index.md")) ==
               "# Reviewed before Content wait\n"
    after
      :global.del_lock(lock, [node()])
      Task.shutdown(publication, :brutal_kill)
    end
  end

  test "workspace drift and frozen source tampering invalidate a successful checked approval" do
    {run, workspace} = run_workspace()
    docs = Path.join(workspace, "priv/docs/index.md")
    write!(docs, "# First review\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    checked = check!(candidate)
    assert {:ok, _} = Candidates.approve(checked.id, checked.digest)
    original_published = Content.current_digest()
    write!(docs, "# Later unreviewed change\n")
    assert {:error, _reason} = Candidates.publish(checked.id, checked.digest)
    assert Content.current_digest() == original_published

    write!(docs, "# First review\n")

    immutable_doc =
      Path.join([candidate.source_path, candidate.app_relative, "priv/docs/index.md"])

    File.chmod!(immutable_doc, 0o644)
    File.write!(immutable_doc, "# Tampered immutable source\n")
    assert {:error, _reason} = Candidates.approve(checked.id, checked.digest)
    assert {:error, _reason} = Candidates.publish(checked.id, checked.digest)
    assert Content.current_digest() == original_published
  end

  test "original source drift and public content CAS changes reject publication", context do
    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "priv/docs/index.md"), "# Candidate\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    candidate = check!(candidate)
    assert {:ok, _} = Candidates.approve(candidate.id, candidate.digest)
    write!(Path.join(context.app, "priv/docs/index.md"), "# Concurrent original edit\n")
    assert {:error, :base_conflict} = Candidates.publish(candidate.id, candidate.digest)

    write!(Path.join(context.app, "priv/docs/index.md"), "# Initial\n\nPublished source.\n")
    competitor = Path.join(context.temporary, "competitor")
    write!(Path.join(competitor, "index.md"), "# Other reviewed publication\n")
    assert {:ok, _} = Content.publish_directory(competitor, candidate.published_base_digest)
    assert {:error, :publication_conflict} = Candidates.publish(candidate.id, candidate.digest)
    assert {:ok, %{body: "# Other reviewed publication\n"}} = Content.get_page("index")
    failed_publication = Candidates.get!(candidate.id)
    assert failed_publication.adoption_status == "adopted"
    assert failed_publication.publication_receipt["source_remains_adopted"]
    assert {:ok, %{workspace: next_workspace}} = Workspaces.create(Ecto.UUID.generate())
    assert File.read!(Path.join(next_workspace, "priv/docs/index.md")) == "# Candidate\n"
  end

  test "reviewed code adoption preserves unrelated current edits and never changes host modules",
       context do
    {run, workspace} = run_workspace()
    authored = Path.join(workspace, "lib/reviewed_code.ex")
    write!(authored, "defmodule CandidateOnly.ReviewedCode do\n  def value, do: :reviewed\nend\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    candidate = check!(candidate)
    assert {:ok, _} = Candidates.approve(candidate.id, candidate.digest)

    assert {:error, :code_deployment_required} =
             Candidates.publish(candidate.id, candidate.digest)

    assert {:error, :deployment_unconfigured} = Candidates.deploy(candidate.id, candidate.digest)
    unrelated = Path.join(context.source, "lib/candidate_library.ex")
    original = File.read!(unrelated)
    write!(unrelated, original <> "\n# Unrelated author change retained.\n")

    assert {:ok, adopted} = Candidates.adopt(candidate.id, candidate.digest)
    durable = adopted.adoption_receipt["source_root"]
    assert durable != context.source

    assert File.read!(Path.join(durable, "lib/candidate_library.ex")) =~
             "Unrelated author change retained."

    assert File.regular?(Path.join([durable, candidate.app_relative, "lib/reviewed_code.ex"]))
    refute File.exists?(Path.join(context.app, "lib/reviewed_code.ex"))
    assert false == :code.is_loaded(CandidateOnly.ReviewedCode)
    assert {:ok, %{workspace: next}} = Workspaces.create(Ecto.UUID.generate())
    assert File.regular?(Path.join(next, "lib/reviewed_code.ex"))

    assert {:error, :adopted_source_requires_new_review} =
             Candidates.deploy(candidate.id, candidate.digest)
  end

  test "adoption refuses a concurrent edit to the reviewed changed path", context do
    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "lib/authored.ex"), authored_source("reviewed-root-library"))
    write!(Path.join(workspace, "test/authored_test.exs"), fixture_test("reviewed-root-library"))
    assert {:ok, candidate} = Candidates.prepare(run.id)
    candidate = check!(candidate)
    assert {:ok, _} = Candidates.approve(candidate.id, candidate.digest)
    concurrent_source = authored_source("concurrent-root-library")
    write!(Path.join(context.app, "lib/authored.ex"), concurrent_source)
    assert {:error, :base_conflict} = Candidates.adopt(candidate.id, candidate.digest)
    assert File.read!(Path.join(context.app, "lib/authored.ex")) == concurrent_source
  end

  test "a missing real native artifact fails offline before any compiler task", context do
    dependencies = source_dependencies!(context.source, ~w(mdex_native rustler_precompiled))
    write!(Path.join(context.app, "mix.exs"), fixture_mix(dependencies))
    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "priv/docs/index.md"), "# Native dependency preflight\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    Editor.subscribe(run.id)
    assert {:ok, _} = Candidates.start_check(candidate.id)
    result = await(candidate.id, &(&1.check_status not in ["pending", "running", "cancelling"]))
    assert result.check_status == "unavailable", result.check_output
    assert result.check_output =~ "native_artifact_unavailable"

    assert [%{"phase" => "dependency_preflight", "exit_status" => 0}] =
             result.check_receipt["steps"]

    assert {:error, :checks_required} = Candidates.approve(candidate.id, candidate.digest)
  end

  test "a real failing authored test persists the actual child exit and cannot be approved" do
    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "test/authored_test.exs"), fixture_test("incorrect expectation"))
    assert {:ok, candidate} = Candidates.prepare(run.id)
    Editor.subscribe(run.id)
    assert {:ok, _} = Candidates.start_check(candidate.id)

    candidate =
      await(candidate.id, &(&1.check_status not in ["pending", "running", "cancelling"]))

    assert candidate.check_status == "failed"
    assert List.last(candidate.check_receipt["steps"])["exit_status"] != 0
    assert {:error, :checks_required} = Candidates.approve(candidate.id, candidate.digest)
    assert false == :code.is_loaded(CandidateOnly.Authored)
  end

  test "cancelling a real Mix child produces cleanup receipts and no successful check" do
    {run, workspace} = run_workspace()

    write!(Path.join(workspace, "test/authored_test.exs"), """
    defmodule CandidateOnly.BlockingTest do
      use ExUnit.Case
      test "a cancellable actual test" do
        receive do
          :never_sent -> :ok
        after
          60_000 -> :ok
        end
      end
    end
    """)

    assert {:ok, candidate} = Candidates.prepare(run.id)
    Editor.subscribe(run.id)
    assert {:ok, _} = Candidates.start_check(candidate.id)
    running = await(candidate.id, &is_map(&1.check_receipt["active_process"]))
    process = running.check_receipt["active_process"]
    assert is_integer(process["os_pid"])
    assert {:ok, _} = Candidates.cancel_check(candidate.id)
    stopped = await(candidate.id, &(&1.check_status not in ["pending", "running", "cancelling"]))
    assert stopped.check_status == "cancelled"
    assert stopped.check_digest == nil
    assert is_map(List.last(stopped.check_receipt["steps"])["cleanup"])
    assert is_map(Runner.stop(process))
    assert {:error, :checks_required} = Candidates.approve(candidate.id, candidate.digest)
  end

  test "a separate real Phoenix release becomes previewable only when ready and is stopped",
       context do
    phoenix_fixture(context.source, context.app)
    {run, workspace} = run_workspace()
    write!(Path.join(workspace, "priv/docs/index.md"), "# Actual isolated Phoenix preview\n")
    assert {:ok, candidate} = Candidates.prepare(run.id)
    candidate = check!(candidate)
    Editor.subscribe(run.id)
    assert {:error, :preview_unavailable} = Candidates.preview_target(candidate.id)
    assert {:ok, starting} = Candidates.start_preview(candidate.id)
    assert starting.preview_status == "starting"
    assert starting.preview_url == nil
    assert {:error, :preview_unavailable} = Candidates.preview_target(candidate.id)
    preview = await(candidate.id, &(&1.preview_status not in ["stopped", "starting"]))
    assert preview.preview_status == "running", inspect(preview.preview_receipt)
    assert preview.preview_url =~ ~r/\Ahttp:\/\/127\.0\.0\.1:\d+\/\z/
    assert http_get!(preview.preview_url) =~ "# Actual isolated Phoenix preview"
    assert false == :code.is_loaded(CandidatePreview.Endpoint)
    assert {:ok, target} = Candidates.preview_target(candidate.id)
    assert target.url == preview.preview_url
    assert target.digest == candidate.digest
    assert target.attempt_id == preview.preview_receipt["attempt_id"]

    assert {:error, :preview_unavailable} =
             Candidates.preview_target(candidate.id,
               digest: String.duplicate("0", 64),
               attempt_id: target.attempt_id
             )

    assert {:error, :preview_unavailable} =
             Candidates.preview_target(candidate.id,
               digest: target.digest,
               attempt_id: Ecto.UUID.generate()
             )

    {other_run, other_workspace} = run_workspace()
    write!(Path.join(other_workspace, "priv/docs/index.md"), "# Other candidate\n")
    assert {:ok, other_candidate} = Candidates.prepare(other_run.id)
    assert {:error, :candidate_resource_limit} = Candidates.start_check(other_candidate.id)

    owner = Process.whereis(OhMyJidoDocs.Candidates.Manager)
    monitor = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 5_000
    recovered = await(candidate.id, &(&1.preview_status == "interrupted"))
    assert recovered.preview_url == nil
    assert recovered.preview_receipt["cleanup"]["status"] == "confirmed"
    assert Process.whereis(OhMyJidoDocs.Candidates.Manager) != owner
    assert {:error, :preview_unavailable} = Candidates.preview_target(candidate.id)
    assert {:ok, _} = Candidates.start_preview(candidate.id)

    preview =
      await(candidate.id, &(&1.preview_status not in ["stopped", "starting", "interrupted"]))

    assert preview.preview_status == "running", inspect(preview.preview_receipt)
    assert http_get!(preview.preview_url) =~ "# Actual isolated Phoenix preview"
    assert {:ok, renewed} = Candidates.preview_target(candidate.id)
    refute renewed.attempt_id == target.attempt_id

    assert {:error, :preview_unavailable} =
             Candidates.preview_target(candidate.id,
               digest: target.digest,
               attempt_id: target.attempt_id
             )

    assert {:ok, _} = Candidates.stop_preview(candidate.id)
    assert {:error, :preview_unavailable} = Candidates.preview_target(candidate.id)
    stopped = await(candidate.id, &(&1.preview_status not in ["running", "starting", "stopping"]))
    assert stopped.preview_status == "stopped"
    assert stopped.preview_url == nil
    assert stopped.preview_receipt["process"]["status"] == "cancelled"
    port = URI.parse(preview.preview_url).port
    assert {:error, _} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 250)
  end

  test "public-only mode cannot initiate any editor or deployment effect" do
    put_setting(:editor_enabled, false)
    on_exit(&OhMyJidoDocs.DataCase.stop_private_workers/0)
    assert Candidates.child_specs() == []
    assert Candidates.list(Ecto.UUID.generate()) == []
    assert {:error, :editor_unavailable} = Candidates.prepare(Ecto.UUID.generate())
    assert {:error, :editor_unavailable} = Candidates.start_check(Ecto.UUID.generate())

    assert {:error, :editor_unavailable} =
             Candidates.deploy(Ecto.UUID.generate(), String.duplicate("1", 64))
  end
end
