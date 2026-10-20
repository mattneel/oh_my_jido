defmodule OhMyJidoDocs.WorkspacesSourceTest do
  use OhMyJidoDocs.DataCase, async: false

  @moduletag :tmp_dir

  import Bitwise

  alias OhMyJidoDocs.Candidates.Source
  alias OhMyJidoDocs.Editor.Run
  alias OhMyJidoDocs.Workspaces

  @app_relative "examples/docs_site"
  @page @app_relative <> "/priv/docs/index.md"
  @configuration [
    :source_root,
    :source_app_path,
    :data_dir,
    :approved_source_paths,
    :packaged_source_paths,
    :source_max_files,
    :source_max_entries,
    :source_max_directories,
    :source_max_depth,
    :source_max_bytes,
    :source_max_file_bytes,
    :source_max_diff_bytes,
    :source_git_executable,
    :source_cleanup_limit,
    :source_cleanup_scan_limit
  ]

  setup %{tmp_dir: temporary} do
    temporary = Path.expand(temporary)
    root = Path.join(temporary, "original")
    data = Path.join(temporary, "durable")
    previous = Map.new(@configuration, &{&1, Application.fetch_env(:oh_my_jido_docs, &1)})

    Enum.each(@configuration, &Application.delete_env(:oh_my_jido_docs, &1))
    Application.put_env(:oh_my_jido_docs, :source_root, root)
    Application.put_env(:oh_my_jido_docs, :source_app_path, @app_relative)
    Application.put_env(:oh_my_jido_docs, :data_dir, data)

    write(root, "mix.exs", "defmodule RootFixture.MixProject do\n  use Mix.Project\nend\n")
    write(root, "lib/original.ex", "defmodule Original do\n  def value, do: :original\nend\n")
    write(root, "vendor/local/lib/local.ex", "defmodule LocalDependency do\nend\n")
    write(root, "config/config.exs", "import Config\n")
    assert :ok = Source.initialize_git(root)

    write(
      root,
      @app_relative <> "/mix.exs",
      "defmodule DocsFixture.MixProject do\n  use Mix.Project\nend\n"
    )

    write(root, @page, "# One\n")
    write(root, @app_relative <> "/bin/build", "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(root, @app_relative <> "/bin/build"), 0o751)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:oh_my_jido_docs, key, value)
        {key, :error} -> Application.delete_env(:oh_my_jido_docs, key)
      end)

      Source.remove_tree(temporary)
    end)

    %{root: root, data: data, temporary: temporary}
  end

  test "retains authored runtime and cache directories without admitting private state", %{
    root: root
  } do
    sources = %{
      "lib/runtime/worker.ex" => "defmodule RuntimeWorker do\nend\n",
      "lib/cache/catalog.ex" => "defmodule CacheCatalog do\nend\n",
      "docs/runtime/index.md" => "# Runtime guide\n"
    }

    private = [
      "runtime/receipt.json",
      "cache/private.txt",
      "lib/runtime/.env",
      "lib/cache/credentials.json",
      "docs/runtime/private.sqlite"
    ]

    Enum.each(sources, fn {path, bytes} -> write(root, path, bytes) end)
    Enum.each(private, &write(root, &1, "synthetic private state\n"))

    assert {:ok, _, 0} =
             Source.git(root, ["add", "--force", "--"] ++ Map.keys(sources) ++ private)

    assert {:ok, %{workspace: workspace}} = Workspaces.create("authored-containers")
    assert {:ok, description} = Workspaces.describe(workspace)

    for {path, bytes} <- sources do
      assert File.read!(Path.join(description.root, path)) == bytes
    end

    for path <- private do
      refute File.exists?(Path.join(description.root, path))
    end
  end

  test "captures dirty tracked bytes plus the generated untracked app, with an app-local Git base",
       %{root: root} do
    dirty = "defmodule Original do\n  def value, do: :dirty\nend\n"
    write(root, "lib/original.ex", dirty)
    write(root, "unapproved.txt", "not approved\n")
    write(root, @app_relative <> "/.env", "DO_NOT_COPY=secret\n")
    write(root, @app_relative <> "/deps/private/source.ex", "not source\n")
    write(root, @app_relative <> "/_build/dev/compiled", "not source\n")
    write(root, @app_relative <> "/priv/static/assets/app.js", "generated\n")
    write(root, @app_relative <> "/priv/static/cache_manifest.json", "{}\n")

    assert {:ok, %{workspace: workspace, base_revision: revision}} = Workspaces.create("dirty")
    assert {:ok, description} = Workspaces.describe(workspace)
    assert File.read!(Path.join(description.root, "lib/original.ex")) == dirty
    assert File.read!(Path.join(workspace, "priv/docs/index.md")) == "# One\n"
    assert description.base_revision == revision
    assert Source.digest(description.base_manifest) == revision
    assert description.app_relative == @app_relative
    assert description.source_root == root
    refute File.exists?(Path.join(description.root, "unapproved.txt"))
    refute File.exists?(Path.join(workspace, ".env"))
    refute File.exists?(Path.join(workspace, "deps"))
    refute File.exists?(Path.join(workspace, "_build"))
    refute File.exists?(Path.join(workspace, "priv/static/assets"))
    refute File.exists?(Path.join(workspace, "priv/static/cache_manifest.json"))
    assert {:ok, output, 0} = Source.git(workspace, ["rev-parse", "--show-toplevel"])
    assert String.trim(output) == workspace
    assert {:ok, _, 0} = Source.git(workspace, ["log", "-1", "--format=%s"])
    assert :ok = Source.verify(description.base_root, description.base_manifest, readonly: true)
    assert :ok = Workspaces.verify_base(root, description.base_manifest)

    write(root, "lib/original.ex", dirty <> "# later edit\n")
    assert {:error, :base_conflict} = Workspaces.verify_base(root, description.base_manifest)
  end

  test "treats a tracked file replaced by a directory as deleted and inventories only approved descendants",
       %{root: root} do
    approved = @app_relative <> "/priv/docs/topic"
    unapproved = "lib/tracked-node"
    write(root, approved, "tracked topic\n")
    write(root, unapproved, "tracked node\n")
    assert {:ok, _, 0} = Source.git(root, ["add", "--", approved, unapproved])
    File.rm!(Path.join(root, approved))
    File.rm!(Path.join(root, unapproved))
    write(root, approved <> "/index.md", "# Nested dirty topic\n")
    write(root, unapproved <> "/unapproved.ex", "not approved source\n")

    assert {:ok, %{workspace: workspace}} = Workspaces.create("dirty-directory")
    assert {:ok, description} = Workspaces.describe(workspace)
    refute Map.has_key?(description.base_manifest, approved)
    refute Map.has_key?(description.base_manifest, unapproved)
    refute Map.has_key?(description.base_manifest, unapproved <> "/unapproved.ex")
    refute File.exists?(Path.join(description.root, unapproved))
    assert description.base_manifest[approved <> "/index.md"]

    assert File.read!(Path.join(workspace, "priv/docs/topic/index.md")) ==
             "# Nested dirty topic\n"

    File.ln_s!("/etc/passwd", Path.join(root, approved <> "/unsafe-link"))
    assert {:error, :unsafe_path} = Workspaces.create("dirty-directory-symlink")
  end

  test "still rejects tracked replacements that are symlinks or unsupported entries", %{
    root: root
  } do
    relative = "lib/tracked-node"
    write(root, relative, "tracked node\n")
    assert {:ok, _, 0} = Source.git(root, ["add", "--", relative])
    path = Path.join(root, relative)
    File.rm!(path)
    File.ln_s!("/etc/passwd", path)
    assert {:error, :unsafe_path} = Source.selected_manifest(root)
    File.rm!(path)
    assert {_, 0} = System.cmd("mkfifo", [path])
    assert {:error, :unsafe_path} = Source.selected_manifest(root)
  end

  test "freezes an exact full-index diff and copies read-only files back to logical modes", %{
    temporary: temporary
  } do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("review")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Two\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-review")

    old_hash = git_blob("# One\n")
    new_hash = git_blob("# Two\n")

    assert frozen.changed_paths == [@page]

    assert frozen.diff ==
             "diff --git a/#{@page} b/#{@page}\n" <>
               "index #{old_hash}..#{new_hash} 100644\n" <>
               "--- a/#{@page}\n+++ b/#{@page}\n" <>
               "@@ -1 +1 @@\n-# One\n+# Two\n"

    assert :ok = Source.verify(frozen.source_path, frozen.manifest, readonly: true)
    assert :ok = Workspaces.verify_workspace(workspace, frozen.workspace_digest)
    assert {:ok, stat} = File.stat(Path.join(frozen.source_path, @page))
    assert band(stat.mode, 0o222) == 0
    refute File.exists?(Path.join(frozen.app_path, ".git"))

    execution = Path.join(temporary, "execution")
    assert :ok = Source.copy(frozen.source_path, execution, frozen.manifest)
    assert {:ok, execution_manifest} = Source.manifest(execution)
    assert execution_manifest == frozen.manifest
    assert Source.digest(execution_manifest) == frozen.digest
    assert {:ok, executable} = File.stat(Path.join(execution, @app_relative <> "/bin/build"))
    assert band(executable.mode, 0o777) == 0o751

    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Changed again\n")

    assert {:error, :workspace_changed} =
             Workspaces.verify_workspace(workspace, frozen.workspace_digest)

    assert File.read!(Path.join(frozen.source_path, @page)) == "# Two\n"
  end

  test "adopts reviewed paths, preserves unrelated current dirty source, and switches future creates",
       %{root: root} do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("adopt")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Reviewed\n")
    write(workspace, "lib/new_feature.ex", "defmodule NewFeature do\nend\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-adopt")

    unrelated = "defmodule Original do\n  def value, do: :unrelated_current_edit\nend\n"
    write(root, "lib/original.ex", unrelated)
    assert {:error, :base_conflict} = Workspaces.verify_base(root, frozen.base_manifest)
    assert {:ok, adopted} = Workspaces.adopt(frozen)
    assert adopted["candidate_digest"] == frozen.digest
    assert adopted["base_revision"] == frozen.base_revision
    refute adopted["source_root"] == root
    assert File.read!(Path.join(root, @page)) == "# One\n"
    assert File.read!(Path.join(root, "lib/original.ex")) == unrelated
    refute File.exists?(Path.join(root, @app_relative <> "/lib/new_feature.ex"))
    assert File.read!(Path.join(adopted["source_root"], "lib/original.ex")) == unrelated
    assert File.read!(Path.join(adopted["source_root"], @page)) == "# Reviewed\n"
    assert {:ok, _, 0} = Source.git(adopted["source_root"], ["log", "-1", "--format=%s"])

    assert {:ok, %{workspace: next, base_revision: next_revision}} =
             Workspaces.create("after-adoption")

    assert next_revision == adopted["digest"]
    assert File.read!(Path.join(next, "priv/docs/index.md")) == "# Reviewed\n"
    assert File.regular?(Path.join(next, "lib/new_feature.ex"))
    assert {:ok, description} = Workspaces.describe(next)
    assert description.source_root == adopted["source_root"]
    assert :ok = Workspaces.verify_base(description.source_root, description.base_manifest)
  end

  test "keeps the source lock through nested same-process operations and releases after exceptions",
       %{root: root} do
    parent = self()

    contender =
      Workspaces.with_source_lock(fn ->
        assert {:ok, %{source_root: ^root}} = Workspaces.current_source()
        assert :nested = Workspaces.with_source_lock(fn -> :nested end)

        contender =
          Task.async(fn ->
            send(parent, :source_contender_started)
            Workspaces.with_source_lock(fn -> :source_contender_acquired end)
          end)

        assert_receive :source_contender_started, 5_000
        assert Task.yield(contender, 20) == nil
        contender
      end)

    assert :source_contender_acquired = Task.await(contender, 30_000)

    assert_raise RuntimeError, "source lock failure", fn ->
      Workspaces.with_source_lock(fn -> raise "source lock failure" end)
    end

    assert :released =
             Task.async(fn -> Workspaces.with_source_lock(fn -> :released end) end)
             |> Task.await(30_000)
  end

  test "makes workspace leases nonblocking, per-workspace, and safely reentrant" do
    assert {:ok, %{workspace: first}} = Workspaces.create("lease-first")
    assert {:ok, %{workspace: second}} = Workspaces.create("lease-second")

    assert :outer =
             Workspaces.with_workspace_lease(first, fn ->
               assert :inner = Workspaces.with_workspace_lease(first, fn -> :inner end)

               assert {:error, :workspace_busy} =
                        Task.async(fn ->
                          Workspaces.with_workspace_lease(first, fn ->
                            File.write!(
                              Path.join(first, "priv/docs/index.md"),
                              "# Must not write\n"
                            )
                          end)
                        end)
                        |> Task.await(30_000)

               assert :ok =
                        Task.async(fn ->
                          Workspaces.with_workspace_lease(second, fn ->
                            File.write!(
                              Path.join(second, "priv/docs/index.md"),
                              "# Other workspace\n"
                            )
                          end)
                        end)
                        |> Task.await(30_000)

               :outer
             end)

    assert File.read!(Path.join(first, "priv/docs/index.md")) == "# One\n"
    assert File.read!(Path.join(second, "priv/docs/index.md")) == "# Other workspace\n"

    assert_raise RuntimeError, "workspace lease failure", fn ->
      Workspaces.with_workspace_lease(first, fn -> raise "workspace lease failure" end)
    end

    assert :released =
             Task.async(fn -> Workspaces.with_workspace_lease(first, fn -> :released end) end)
             |> Task.await(30_000)
  end

  test "refuses review and adoption for the full active managed writer lifetime", %{data: data} do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("writer-lifetime")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Approved before writer\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-writer-lifetime")
    parent = self()

    writer =
      Task.async(fn ->
        Workspaces.with_workspace_lease(workspace, fn ->
          assert :nested_writer =
                   Workspaces.with_workspace_lease(workspace, fn -> :nested_writer end)

          send(parent, :writer_lease_acquired)

          receive do
            :edit ->
              File.write!(Path.join(workspace, "priv/docs/index.md"), "# Managed writer edit\n")
              send(parent, :writer_edit_completed)

              receive do
                :release -> :ok
              end

            :release ->
              :ok
          end
        end)
      end)

    try do
      assert_receive :writer_lease_acquired, 5_000
      assert :ok = Workspaces.verify_workspace(workspace, frozen.workspace_digest)
      assert {:error, :workspace_busy} = Workspaces.adopt(frozen)
      assert {:error, :workspace_busy} = Workspaces.freeze(workspace, "candidate-during-writer")
      refute File.exists?(Path.join(data, "source/current.json"))
      send(writer.pid, :edit)
      assert_receive :writer_edit_completed, 5_000
      assert {:error, :workspace_busy} = Workspaces.adopt(frozen)
      refute File.exists?(Path.join(data, "source/current.json"))
    after
      send(writer.pid, :release)
    end

    assert :ok = Task.await(writer, 30_000)
    assert {:error, :workspace_changed} = Workspaces.adopt(frozen)
    refute File.exists?(Path.join(data, "source/current.json"))
    assert {:ok, []} = File.ls(Path.join(data, "source_allocations"))
  end

  test "rejects durable pending, token-only, and active managed writers inside a reentrant workspace lease",
       %{data: data} do
    assert {:ok, %{workspace: workspace, base_revision: revision}} =
             Workspaces.create("durable-writer-guard")

    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Reviewed durable guard\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-durable-writer-guard")
    run = managed_run(workspace, revision)

    pending =
      run
      |> Ecto.Changeset.change(
        source_writer_pending: true,
        source_writer_token: Ecto.UUID.generate()
      )
      |> Repo.update!()

    assert :ok =
             Workspaces.with_workspace_lease(workspace, fn ->
               assert {:error, :workspace_busy} = Workspaces.adopt(frozen)

               assert {:error, :workspace_busy} =
                        Workspaces.freeze(workspace, "pending-writer-review")

               :ok
             end)

    refute File.exists?(Path.join(data, "source/current.json"))

    token_only =
      pending
      |> Ecto.Changeset.change(source_writer_pending: false)
      |> Repo.update!()

    assert {:error, :workspace_busy} = Workspaces.adopt(frozen)
    assert {:error, :workspace_busy} = Workspaces.freeze(workspace, "token-writer-review")
    refute File.exists?(Path.join(data, "source/current.json"))

    active =
      Enum.reduce(~w(queued running waiting cancelling suspending), token_only, fn status, row ->
        row =
          row
          |> Ecto.Changeset.change(
            source_writer_pending: false,
            source_writer_token: nil,
            status: status
          )
          |> Repo.update!()

        assert {:error, :workspace_busy} = Workspaces.adopt(frozen)
        assert {:error, :workspace_busy} = Workspaces.freeze(workspace, "active-writer-review")
        refute File.exists?(Path.join(data, "source/current.json"))
        row
      end)

    active |> Ecto.Changeset.change(status: "completed") |> Repo.update!()
    assert {:ok, adopted} = Workspaces.adopt(frozen)
    assert File.read!(Path.join(adopted["source_root"], @page)) == "# Reviewed durable guard\n"
  end

  test "rechecks durable writer settlement after staging even when workspace bytes are unchanged",
       %{data: data, temporary: temporary} do
    assert {:ok, %{workspace: workspace, base_revision: revision}} =
             Workspaces.create("late-durable-writer")

    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Reviewed late writer\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-late-durable-writer")
    run = managed_run(workspace, revision)
    gate = adoption_git_gate(temporary)
    ready = Task.async(fn -> await_git_staging(gate.ready) end)
    adoption = Task.async(fn -> Workspaces.adopt(frozen) end)

    try do
      assert "staging\n" = Task.await(ready, 30_000)

      run
      |> Ecto.Changeset.change(
        source_writer_pending: true,
        source_writer_token: Ecto.UUID.generate()
      )
      |> Repo.update!()

      assert :ok = Workspaces.verify_workspace(workspace, frozen.workspace_digest)
    after
      File.write!(gate.release, "continue\n")
      Application.delete_env(:oh_my_jido_docs, :source_git_executable)
    end

    assert {:error, :workspace_busy} = Task.await(adoption, 30_000)
    refute File.exists?(Path.join(data, "source/current.json"))
    assert {:ok, []} = File.ls(Path.join(data, "source_allocations"))
  end

  test "revalidates the protected workspace after real Git staging without replacing the canonical pointer",
       %{root: root, data: data, temporary: temporary} do
    assert {:ok, %{workspace: baseline}} = Workspaces.create("race-baseline")
    File.write!(Path.join(baseline, "priv/docs/index.md"), "# Existing canonical\n")
    assert {:ok, baseline_candidate} = Workspaces.freeze(baseline, "candidate-race-baseline")
    assert {:ok, adopted} = Workspaces.adopt(baseline_candidate)
    assert {:ok, %{workspace: workspace}} = Workspaces.create("race-workspace")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Approved race content\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-workspace-race")

    claimed = %{
      frozen
      | workspace: baseline,
        workspace_digest: baseline_candidate.workspace_digest
    }

    pointer = Path.join(data, "source/current.json")
    original_pointer = File.read!(pointer)
    gate = adoption_git_gate(temporary)
    ready = Task.async(fn -> await_git_staging(gate.ready) end)
    adoption = Task.async(fn -> Workspaces.adopt(claimed) end)

    try do
      assert "staging\n" = Task.await(ready, 30_000)

      assert {:error, :workspace_busy} =
               Task.async(fn ->
                 Workspaces.with_workspace_lease(workspace, fn ->
                   File.write!(Path.join(workspace, "priv/docs/index.md"), "# Managed race\n")
                 end)
               end)
               |> Task.await(30_000)

      assert :ok =
               Task.async(fn ->
                 File.write!(
                   Path.join(workspace, "priv/docs/index.md"),
                   "# Concurrent raw edit\n"
                 )
               end)
               |> Task.await(30_000)

      assert File.read!(pointer) == original_pointer
    after
      File.write!(gate.release, "continue\n")
      Application.delete_env(:oh_my_jido_docs, :source_git_executable)
    end

    assert {:error, :workspace_changed} = Task.await(adoption, 30_000)
    assert File.read!(pointer) == original_pointer
    assert File.read!(Path.join(root, @page)) == "# One\n"
    assert File.read!(Path.join(adopted["source_root"], @page)) == "# Existing canonical\n"
    assert File.read!(Path.join(frozen.source_path, @page)) == "# Approved race content\n"
    assert {:ok, %{source_root: current}} = Workspaces.current_source()
    assert current == adopted["source_root"]
    assert {:ok, []} = File.ls(Path.join(data, "source_allocations"))

    {:ok, names} = File.ls(Path.join(data, "source_cleanup"))
    [name] = Enum.filter(names, &String.starts_with?(&1, "adopt-"))
    cleanup = data |> Path.join("source_cleanup/#{name}") |> File.read!() |> Jason.decode!()
    assert cleanup["operation"] == "adopt"
    assert cleanup["status"] == "complete"
    assert [%{"path" => rejected_source, "status" => "removed"}] = cleanup["items"]
    refute File.exists?(rejected_source)
  end

  test "rejects a dirty original conflict without installing a source pointer", %{
    root: root,
    data: data
  } do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("conflict")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Candidate\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-conflict")
    write(root, @page, "# Concurrent host edit\n")

    assert {:error, :base_conflict} = Workspaces.adopt(frozen)
    refute File.exists?(Path.join(data, "source/current.json"))
    assert File.read!(Path.join(root, @page)) == "# Concurrent host edit\n"
    assert {:ok, %{source_root: ^root}} = Workspaces.current_source()
  end

  test "rejects a stale adoption pointer and tampered candidate metadata", %{root: root} do
    assert {:ok, %{workspace: first}} = Workspaces.create("first")
    assert {:ok, %{workspace: second}} = Workspaces.create("second")
    File.write!(Path.join(first, "priv/docs/index.md"), "# First\n")
    write(second, "priv/docs/second.md", "# Second\n")
    assert {:ok, a} = Workspaces.freeze(first, "candidate-first")
    assert {:ok, b} = Workspaces.freeze(second, "candidate-second")
    assert {:error, :invalid_candidate} = Workspaces.adopt(%{a | source_root: a.source_path})
    assert {:ok, adopted} = Workspaces.adopt(a)
    assert {:error, :source_pointer_conflict} = Workspaces.adopt(b)
    assert {:ok, %{source_root: current}} = Workspaces.current_source()
    assert current == adopted["source_root"]
    assert File.read!(Path.join(root, @page)) == "# One\n"
  end

  test "rejects candidate additions and symlink substitutions after review" do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("tampered")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Reviewed tamper test\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-tampered")
    File.chmod!(frozen.source_path, 0o755)
    write(frozen.source_path, "extra.ex", "defmodule Unreviewed do\nend\n")

    assert {:error, :source_changed} =
             Source.verify(frozen.source_path, frozen.manifest, readonly: true)

    assert {:error, :candidate_changed} = Workspaces.adopt(frozen)
    File.rm!(Path.join(frozen.source_path, "extra.ex"))
    File.chmod!(Path.join(frozen.source_path, "lib"), 0o755)
    File.rm!(Path.join(frozen.source_path, "lib/original.ex"))
    File.ln_s!("/etc/passwd", Path.join(frozen.source_path, "lib/original.ex"))
    File.chmod!(Path.join(frozen.source_path, "lib"), 0o555)
    File.chmod!(frozen.source_path, 0o555)

    assert {:error, :unsafe_path} =
             Source.verify(frozen.source_path, frozen.manifest, readonly: true)
  end

  test "rejects an unchanged workspace before creating a candidate directory", %{data: data} do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("unchanged")
    assert {:error, :no_changes} = Workspaces.freeze(workspace, "candidate-unchanged")
    refute File.exists?(Path.join(data, "candidates/candidate-unchanged"))
    refute File.exists?(Path.join(data, "candidate_metadata/candidate-unchanged.json"))
  end

  test "uses a confined packaged allowlist when the original has no Git metadata", %{root: root} do
    Source.remove_tree(Path.join(root, ".git"))
    write(root, "not-packaged/source.ex", "not approved\n")
    assert {:ok, %{workspace: workspace}} = Workspaces.create("packaged")
    assert {:ok, description} = Workspaces.describe(workspace)
    assert File.regular?(Path.join(description.root, "vendor/local/lib/local.ex"))
    refute File.exists?(Path.join(description.root, "not-packaged"))
    assert File.read!(Path.join(workspace, "priv/docs/index.md")) == "# One\n"
  end

  test "rejects source symlinks and validates bytes while copying", %{
    root: root,
    temporary: temporary
  } do
    assert {:ok, manifest} = Source.manifest(root)
    write(root, @page, "# Six\n")

    assert {:error, :source_changed} =
             Source.copy(root, Path.join(temporary, "changed-copy"), manifest)

    refute File.exists?(Path.join(temporary, "changed-copy"))
    File.ln_s!("/etc/passwd", Path.join(root, @app_relative <> "/escaped"))
    assert {:error, :unsafe_path} = Source.manifest(root)
    assert {:error, :unsafe_path} = Workspaces.create("unsafe")
  end

  test "bounds source and review output without truncation, with explicit dependency inventory overrides",
       %{root: root} do
    Application.put_env(:oh_my_jido_docs, :source_max_files, 1)
    assert {:error, :source_too_large} = Source.manifest(root)
    assert {:ok, _} = Source.manifest(root, max_files: 100, max_bytes: 10_000)
    assert {:error, :source_too_large} = Source.manifest(root, max_files: 100, max_bytes: 2)
    Application.delete_env(:oh_my_jido_docs, :source_max_files)

    assert {:ok, %{workspace: workspace}} = Workspaces.create("bounded")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Too large for the review limit\n")
    Application.put_env(:oh_my_jido_docs, :source_max_diff_bytes, 16)
    assert {:error, :diff_too_large} = Workspaces.freeze(workspace, "candidate-bounded")
  end

  test "bounds empty directories, every listed entry, and depth independently of regular files",
       %{temporary: temporary} do
    root = Path.join(temporary, "inventory-bounds")
    File.mkdir_p!(Path.join(root, "left"))
    File.mkdir_p!(Path.join(root, "right"))

    assert {:ok, %{}} =
             Source.manifest(root, max_files: 1, max_entries: 3, max_directories: 3, max_depth: 1)

    assert {:error, :source_too_large} = Source.manifest(root, max_entries: 2)
    assert {:error, :source_too_large} = Source.manifest(root, max_directories: 2)
    assert {:error, :source_too_large} = Source.verify(root, %{}, max_directories: 2)
    assert :ok = Source.verify(root, %{}, max_entries: 3, max_directories: 3, max_depth: 1)
    File.mkdir_p!(Path.join(root, "left/deeper"))
    assert {:error, :source_too_large} = Source.manifest(root, max_depth: 1)
    assert {:ok, %{}} = Source.manifest(root, max_depth: 2)
    assert {:error, :source_too_large} = Source.verify(root, %{}, max_depth: 1)

    excluded = Path.join(temporary, "excluded-entry-bounds")
    File.mkdir_p!(Path.join(excluded, ".git"))
    write(excluded, ".env", "excluded\n")
    assert {:ok, %{}} = Source.manifest(excluded, max_entries: 3)
    assert {:error, :source_too_large} = Source.manifest(excluded, max_entries: 2)
  end

  test "rejects an oversized listing before sorting or inspecting its first unsafe descendant",
       %{temporary: temporary} do
    root = Path.join(temporary, "wide-inventory")
    File.mkdir_p!(root)
    File.ln_s!("/etc/passwd", Path.join(root, "000-unsafe"))
    Enum.each(1..4, &File.mkdir_p!(Path.join(root, "empty-#{&1}")))
    assert {:error, :source_too_large} = Source.manifest(root, max_entries: 5)
    assert {:error, :unsafe_path} = Source.manifest(root, max_entries: 6)
  end

  test "shares inventory budgets across selected roots and tracked or packaged source", %{
    root: root
  } do
    File.mkdir_p!(Path.join(root, "source-a/empty"))
    File.mkdir_p!(Path.join(root, "source-b/empty"))
    Application.put_env(:oh_my_jido_docs, :approved_source_paths, ["source-b", "source-a"])

    assert {:ok, _} = Source.manifest(root, paths: ["source-a"], max_entries: 2)
    assert {:ok, _} = Source.manifest(root, paths: ["source-b"], max_entries: 2)

    assert {:error, :source_too_large} =
             Source.manifest(root, paths: ["source-a", "source-b"], max_entries: 3)

    assert {:ok, %{}} =
             Source.manifest(root,
               paths: ["source-a/empty", "source-b", "source-a"],
               max_entries: 4
             )

    assert {:error, :source_too_large} = Source.selected_manifest(root, max_entries: 7)
    assert {:ok, selected} = Source.selected_manifest(root, max_entries: 8)
    assert Map.has_key?(selected, "mix.exs")
    assert map_size(selected) == 4

    Source.remove_tree(Path.join(root, ".git"))
    Application.put_env(:oh_my_jido_docs, :approved_source_paths, ["source-a"])
    Application.put_env(:oh_my_jido_docs, :packaged_source_paths, ["source-b"])
    assert {:error, :source_too_large} = Source.selected_manifest(root, max_entries: 3)
    assert {:ok, %{}} = Source.selected_manifest(root, max_entries: 4)
  end

  test "applies global entry and depth limits to source creation and later review",
       %{root: root, data: data} do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("bounded-editable")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Bounded review\n")
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-bounded-editable")
    Enum.each(1..64, &File.mkdir_p!(Path.join(workspace, "empty-#{&1}")))
    Enum.each(1..64, &File.mkdir_p!(Path.join(root, @app_relative <> "/empty-#{&1}")))
    Application.put_env(:oh_my_jido_docs, :source_max_entries, 64)
    assert {:error, :source_too_large} = Workspaces.create("bounded-original")

    assert {:error, :source_too_large} =
             Workspaces.freeze(workspace, "candidate-over-entry-limit")

    refute File.exists?(Path.join(data, "candidate_metadata/candidate-over-entry-limit.json"))
    Application.delete_env(:oh_my_jido_docs, :source_max_entries)
    Application.put_env(:oh_my_jido_docs, :source_max_depth, 5)
    File.mkdir_p!(Path.join(workspace, "priv/docs/deep/too-deep"))

    assert {:error, :source_too_large} =
             Workspaces.freeze(workspace, "candidate-over-depth-limit")

    assert {:error, :source_too_large} = Workspaces.adopt(frozen)
    refute File.exists?(Path.join(data, "source/current.json"))
    assert File.read!(Path.join(root, @page)) == "# One\n"
  end

  test "adopts file-directory transitions and full permission changes without unrelated loss", %{
    root: root
  } do
    write(root, @app_relative <> "/priv/docs/switch", "old file\n")
    assert {:ok, %{workspace: workspace}} = Workspaces.create("transition")
    File.rm!(Path.join(workspace, "priv/docs/switch"))
    write(workspace, "priv/docs/switch/nested.md", "# Nested\n")
    File.chmod!(Path.join(workspace, "bin/build"), 0o711)
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-transition")
    assert frozen.diff =~ "old mode 100751\nnew mode 100711\n"
    assert {:ok, adopted} = Workspaces.adopt(frozen)

    assert File.read!(
             Path.join(adopted["source_root"], @app_relative <> "/priv/docs/switch/nested.md")
           ) == "# Nested\n"

    assert {:ok, stat} =
             File.stat(Path.join(adopted["source_root"], @app_relative <> "/bin/build"))

    assert band(stat.mode, 0o777) == 0o511
    assert File.read!(Path.join(root, @app_relative <> "/priv/docs/switch")) == "old file\n"
  end

  test "reviews non-UTF-8 source as a lossless Git binary patch", %{temporary: temporary} do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("binary")
    write(workspace, "priv/docs/bytes.dat", <<255, 10>>)
    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-binary")
    assert String.valid?(frozen.diff)
    assert frozen.diff =~ "GIT binary patch"
    execution = Path.join(temporary, "binary-execution")
    assert :ok = Source.copy(frozen.source_path, execution, frozen.manifest)

    assert File.read!(Path.join(execution, @app_relative <> "/priv/docs/bytes.dat")) ==
             <<255, 10>>

    assert {:ok, adopted} = Workspaces.adopt(frozen)

    assert File.read!(Path.join(adopted["source_root"], @app_relative <> "/priv/docs/bytes.dat")) ==
             <<255, 10>>
  end

  test "keeps public PEM bundles as source without relaxing private-key path exclusions", %{
    root: root,
    temporary: temporary
  } do
    relative = @app_relative <> "/priv/certificates/public-bundle.pem"

    public =
      pem("CERTIFICATE", "public certificate bytes") <> pem("PUBLIC KEY", "public key bytes")

    write(root, relative, public)

    write(
      root,
      @app_relative <> "/priv/certificates/private.key",
      pem("PRIVATE KEY", "private bytes")
    )

    write(root, @app_relative <> "/priv/certificates/private.p12", "private container bytes")
    write(root, @app_relative <> "/priv/certificates/private.pfx", "private container bytes")

    assert {:ok, manifest} = Source.manifest(root)
    assert manifest[relative]["size"] == byte_size(public)
    refute Map.has_key?(manifest, @app_relative <> "/priv/certificates/private.key")
    refute Map.has_key?(manifest, @app_relative <> "/priv/certificates/private.p12")
    refute Map.has_key?(manifest, @app_relative <> "/priv/certificates/private.pfx")
    destination = Path.join(temporary, "public-pem-copy")
    assert :ok = Source.copy(root, destination, manifest)
    assert File.read!(Path.join(destination, relative)) == public
    refute File.exists?(Path.join(destination, @app_relative <> "/priv/certificates/private.key"))
  end

  test "rejects PEM private-key labels during inventory and independently during copying", %{
    root: root,
    temporary: temporary
  } do
    relative = @app_relative <> "/priv/certificates/material.pem"

    for label <- [
          "PRIVATE KEY",
          "ENCRYPTED PRIVATE KEY",
          "RSA PRIVATE KEY",
          "EC PRIVATE KEY",
          "DSA PRIVATE KEY",
          "OPENSSH PRIVATE KEY",
          "SSH2 ENCRYPTED PRIVATE KEY"
        ] do
      contents = pem("CERTIFICATE", "public bytes") <> pem(label, "private material")
      write(root, relative, contents)
      assert {:error, :private_key_source} = Source.manifest(root)
      assert {:error, :private_key_source} = Source.selected_manifest(root)
      destination = Path.join(temporary, "private-pem-copy")

      assert {:error, :private_key_source} =
               Source.copy(root, destination, single_manifest(relative, contents))

      refute File.exists?(destination)
    end
  end

  test "finds private-key boundaries split across read chunks regardless of extension", %{
    root: root,
    temporary: temporary
  } do
    relative = @app_relative <> "/priv/certificates/material.txt"

    contents =
      String.duplicate("x", 65_536 - 13) <>
        "\n" <> pem("ENCRYPTED PRIVATE KEY", "private material")

    write(root, relative, contents)
    assert {:error, :private_key_source} = Source.manifest(root)
    destination = Path.join(temporary, "split-private-key-copy")

    assert {:error, :private_key_source} =
             Source.copy(root, destination, single_manifest(relative, contents))

    refute File.exists?(destination)
  end

  test "does not classify a quoted PEM boundary as a private-key block", %{root: root} do
    relative = @app_relative <> "/lib/public_documentation.ex"

    contents =
      "defmodule PublicDocumentation do\n  @label \"" <>
        "-----BEGIN " <> "PRIVATE KEY-----\"\nend\n"

    write(root, relative, contents)
    assert {:ok, manifest} = Source.manifest(root)
    assert Map.has_key?(manifest, relative)
  end

  test "reviews full POSIX permissions for same-executable-bit changes and additions/deletions" do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("permissions")
    File.chmod!(Path.join(workspace, "priv/docs/index.md"), 0o600)
    write(workspace, "priv/docs/restricted.md", "# Restricted\n")
    File.chmod!(Path.join(workspace, "priv/docs/restricted.md"), 0o640)
    File.rm!(Path.join(workspace, "bin/build"))

    assert {:ok, frozen} = Workspaces.freeze(workspace, "candidate-permissions")
    assert frozen.diff =~ "old POSIX mode 0644\nnew POSIX mode 0600\n"
    assert frozen.diff =~ "new POSIX mode 0640\n"
    assert frozen.diff =~ "old POSIX mode 0751\n"
  end

  test "recovers a completed allocation and discards a cancelled run under the source lock", %{
    root: root,
    data: data
  } do
    id = "11111111-2222-3333-4444-555555555555"
    assert {:error, :not_found} = Workspaces.fetch(id)
    assert {:ok, allocated} = Workspaces.create(id)
    assert {:ok, ^allocated} = Workspaces.fetch(id)
    original = File.read!(Path.join(root, @page))
    lock = {{Workspaces, data}, self()}
    assert :global.set_lock(lock, [node()])
    parent = self()

    cleanup =
      Task.async(fn ->
        send(parent, :discard_started)
        Workspaces.discard(id)
      end)

    try do
      assert_receive :discard_started
      assert Task.yield(cleanup, 20) == nil
      assert File.dir?(allocated.workspace)
    after
      :global.del_lock(lock, [node()])
    end

    assert :ok = Task.await(cleanup, 30_000)
    assert {:error, :not_found} = Workspaces.fetch(id)
    assert {:ok, []} = File.ls(Path.join(data, "workspaces"))
    assert {:ok, []} = File.ls(Path.join(data, "workspace_metadata"))
    assert {:ok, []} = File.ls(Path.join(data, "source_allocations"))
    assert File.read!(Path.join(root, @page)) == original

    receipt =
      data |> Path.join("source_cleanup/discard-#{id}.json") |> File.read!() |> Jason.decode!()

    assert receipt["status"] == "complete"

    assert Enum.any?(
             receipt["items"],
             &(&1["path"] == Path.join(data, "workspaces/#{id}") and &1["status"] == "removed")
           )

    assert :ok = Workspaces.discard(id)
  end

  test "retains a cancelled workspace base referenced by protected candidate metadata", %{
    data: data
  } do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("referenced")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Candidate base reference\n")
    assert {:ok, candidate} = Workspaces.freeze(workspace, "candidate-referenced")
    assert {:error, :candidate_references_workspace} = Workspaces.discard("referenced")
    assert {:ok, %{workspace: ^workspace}} = Workspaces.fetch("referenced")
    assert :ok = Source.verify(candidate.base_root, candidate.base_manifest, readonly: true)

    receipt =
      data
      |> Path.join("source_cleanup/discard-referenced.json")
      |> File.read!()
      |> Jason.decode!()

    assert receipt["status"] == "uncertain"
    assert Enum.any?(receipt["items"], &(&1["status"] == "retained"))
  end

  test "discards only the named interrupted allocation, including uncommitted metadata", %{
    root: root,
    data: data
  } do
    assert {:ok, _} = Workspaces.current_source()
    record = allocation_fixture(data, "workspace", "cancel-copy")
    write(record["staging"], "source/partial.ex", "defmodule PartialCopy do\nend\n")

    write(
      data,
      "workspace_metadata/cancel-copy.json.staging-#{String.duplicate("a", 32)}",
      "{\"schema\":"
    )

    write(data, "workspaces/unrelated/keep.txt", "keep this allocation\n")
    original = File.read!(Path.join(root, @page))

    assert :ok = Workspaces.discard("cancel-copy")
    refute File.exists?(record["staging"])
    refute File.exists?(record["lease"])
    assert {:ok, []} = File.ls(Path.join(data, "workspace_metadata"))

    assert File.read!(Path.join(data, "workspaces/unrelated/keep.txt")) ==
             "keep this allocation\n"

    assert File.read!(Path.join(root, @page)) == original
  end

  test "reconciles owned copy and post-rename orphans while retaining completed allocations", %{
    root: root,
    data: data
  } do
    orphan = "22222222-3333-4444-5555-666666666666"
    assert {:ok, %{workspace: workspace}} = Workspaces.create(orphan)
    assert {:ok, completed} = Workspaces.create("completed-recovery")
    final = allocation_fixture(data, "workspace", orphan)
    File.rm!(final["metadata"])
    pending = allocation_fixture(data, "workspace", "partial-recovery")
    write(pending["staging"], "source/partial.ex", "incomplete source bytes\n")
    write(pending["staging"], ".source-diff-owned/b/changed.ex", "unfinished review bytes\n")

    write(
      data,
      "workspace_metadata/partial-recovery.json.staging-#{String.duplicate("b", 32)}",
      "{"
    )

    completed_record = allocation_fixture(data, "workspace", "completed-recovery")
    write(completed_record["staging"], "source/unused-copy.ex", "unused interrupted duplicate\n")
    original = File.read!(Path.join(root, @page))

    assert File.dir?(workspace)
    assert {:ok, receipt} = Workspaces.reconcile_staging()
    assert receipt["status"] == "complete"
    refute File.exists?(final["final"])
    refute File.exists?(pending["staging"])
    refute File.exists?(completed_record["staging"])
    assert {:ok, ^completed} = Workspaces.fetch("completed-recovery")
    assert File.read!(Path.join(root, @page)) == original
    assert File.read!(receipt["receipt_path"]) |> Jason.decode!() == receipt

    assert Enum.any?(
             receipt["items"],
             &(&1["path"] == completed_record["final"] and &1["status"] == "preserved")
           )

    assert {:ok, []} = File.ls(Path.join(data, "source_allocations"))
  end

  test "reconciles unfinished candidate snapshots but never removes completed frozen candidates",
       %{data: data} do
    assert {:ok, %{workspace: workspace}} = Workspaces.create("candidate-recovery")
    File.write!(Path.join(workspace, "priv/docs/index.md"), "# Review recovery\n")
    assert {:ok, incomplete} = Workspaces.freeze(workspace, "candidate-incomplete")
    assert {:ok, completed} = Workspaces.freeze(workspace, "candidate-completed")
    orphan = allocation_fixture(data, "candidate", "candidate-incomplete")
    File.rm!(orphan["metadata"])
    kept = allocation_fixture(data, "candidate", "candidate-completed")
    write(kept["staging"], "source/partial.ex", "interrupted extra copy\n")
    assert {:ok, receipt} = Workspaces.reconcile_staging()
    assert receipt["status"] == "complete"
    refute File.exists?(incomplete.source_path)
    refute File.exists?(orphan["lease"])
    refute File.exists?(kept["staging"])
    assert :ok = Source.verify(completed.source_path, completed.manifest, readonly: true)
    assert File.regular?(kept["metadata"])
  end

  test "removes an owned uncommitted adoption but preserves current and historical canonical source",
       %{data: data} do
    assert {:ok, %{workspace: first}} = Workspaces.create("source-recovery-first")
    File.write!(Path.join(first, "priv/docs/index.md"), "# First canonical\n")
    assert {:ok, a} = Workspaces.freeze(first, "candidate-source-first")
    assert {:ok, original_adoption} = Workspaces.adopt(a)
    assert {:ok, %{workspace: second}} = Workspaces.create("source-recovery-second")
    File.write!(Path.join(second, "priv/docs/index.md"), "# Second canonical\n")
    assert {:ok, b} = Workspaces.freeze(second, "candidate-source-second")
    assert {:ok, current_adoption} = Workspaces.adopt(b)
    allocation_fixture(data, "source", Path.basename(original_adoption["source_root"]))
    allocation_fixture(data, "source", Path.basename(current_adoption["source_root"]))

    orphan = allocation_fixture(data, "source", String.duplicate("c", 32))
    assert :ok = Source.copy(b.source_path, orphan["final"], b.manifest)
    assert :ok = Source.initialize_git(orphan["final"])
    assert :ok = Source.read_only(orphan["final"], b.manifest)
    write(orphan["staging"], "partial.ex", "incomplete adoption\n")
    write(hd(orphan["auxiliary"]), "reviewed.ex", "incomplete reviewed overlay\n")
    pointer = File.read!(Path.join(data, "source/current.json"))

    assert {:ok, receipt} = Workspaces.reconcile_staging()
    assert receipt["status"] == "complete"
    refute File.exists?(orphan["final"])
    refute File.exists?(orphan["staging"])
    refute File.exists?(hd(orphan["auxiliary"]))
    assert File.dir?(original_adoption["source_root"])
    assert File.dir?(current_adoption["source_root"])
    assert File.read!(Path.join(data, "source/current.json")) == pointer
    assert {:ok, %{source_root: canonical}} = Workspaces.current_source()
    assert canonical == current_adoption["source_root"]
  end

  test "retains unowned UUID/staging directories and rejects forged ownership evidence", %{
    root: root,
    data: data
  } do
    assert {:ok, _} = Workspaces.current_source()
    unknown = Path.join(data, "workspaces/33333333-4444-5555-6666-777777777777")
    write(unknown, "unrelated.txt", "not an owned workspace\n")
    write(data, "candidates/.staging-unowned/keep.txt", "not an owned candidate\n")
    forged = allocation_fixture(data, "workspace", "forged-owner")
    File.write!(forged["lease"], Jason.encode!(Map.put(forged, "final", root)))

    assert {:error, {:staging_cleanup_uncertain, receipt}} = Workspaces.reconcile_staging()
    assert receipt["status"] == "uncertain"
    assert File.read!(Path.join(unknown, "unrelated.txt")) == "not an owned workspace\n"

    assert File.read!(Path.join(data, "candidates/.staging-unowned/keep.txt")) ==
             "not an owned candidate\n"

    assert File.dir?(root)
    assert File.regular?(forged["lease"])
    assert Enum.any?(receipt["items"], &(&1["path"] == unknown and &1["status"] == "retained"))
  end

  test "advances a persisted bounded cleanup cursor past retained uncertainty", %{data: data} do
    assert {:ok, _} = Workspaces.current_source()
    a = allocation_fixture(data, "workspace", "batch-a")
    b = allocation_fixture(data, "workspace", "batch-b")
    write(a["staging"], "source/partial.ex", "first partial copy\n")
    write(b["staging"], "source/partial.ex", "second partial copy\n")
    write(data, "source_allocations/000-unknown-owner", "unknown ownership\n")
    Application.put_env(:oh_my_jido_docs, :source_cleanup_limit, 1)

    assert {:error, {:staging_cleanup_uncertain, first}} = Workspaces.reconcile_staging()
    assert first["remaining"] == 2
    assert {:ok, second} = Workspaces.reconcile_staging()
    assert second["remaining"] == 2
    assert {:ok, third} = Workspaces.reconcile_staging()
    assert third["remaining"] == 1
    refute File.exists?(a["staging"])
    refute File.exists?(b["staging"])
    assert File.regular?(Path.join(data, "source_allocations/000-unknown-owner"))
    assert File.read!(third["receipt_path"]) |> Jason.decode!() == third
  end

  test "persists scan-limit uncertainty without deleting unexamined source", %{data: data} do
    assert {:ok, _} = Workspaces.current_source()
    a = allocation_fixture(data, "workspace", "scan-a")
    b = allocation_fixture(data, "workspace", "scan-b")
    write(a["staging"], "partial.ex", "first partial copy\n")
    write(b["staging"], "partial.ex", "second partial copy\n")
    Application.put_env(:oh_my_jido_docs, :source_cleanup_scan_limit, 1)

    assert {:error, {:staging_cleanup_uncertain, receipt}} = Workspaces.reconcile_staging()
    assert receipt["status"] == "uncertain"
    assert File.dir?(a["staging"])
    assert File.dir?(b["staging"])
    assert File.read!(receipt["receipt_path"]) |> Jason.decode!() == receipt
  end

  defp write(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    File.chmod!(path, 0o644)
  end

  defp git_blob(bytes) do
    :crypto.hash(:sha, ["blob ", Integer.to_string(byte_size(bytes)), <<0>>, bytes])
    |> Base.encode16(case: :lower)
  end

  defp pem(label, bytes) do
    "-----BEGIN " <>
      label <>
      "-----\n" <>
      Base.encode64(bytes) <>
      "\n-----END " <> label <> "-----\n"
  end

  defp single_manifest(relative, bytes) do
    %{
      relative => %{
        "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
        "mode" => 0o644,
        "size" => byte_size(bytes)
      }
    }
  end

  defp await_git_staging(path, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 30_000

    case File.read(path) do
      {:ok, "staging\n"} -> "staging\n"
      {:ok, _in_progress} -> retry_git_staging(path, deadline)
      {:error, :enoent} -> retry_git_staging(path, deadline)
      {:error, reason} -> flunk("Git staging marker could not be read: #{inspect(reason)}")
    end
  end

  defp retry_git_staging(path, deadline) do
    assert System.monotonic_time(:millisecond) < deadline,
           "Git did not reach its staging barrier within the existing 30-second deadline"

    Process.sleep(10)
    await_git_staging(path, deadline)
  end

  defp adoption_git_gate(temporary) do
    ready = Path.join(temporary, "adoption-git-ready")
    release = Path.join(temporary, "adoption-git-release")
    executable = Path.join(temporary, "adoption-git")
    git = System.find_executable("git")
    assert is_binary(git)

    File.write!(executable, """
    #!/bin/sh
    for argument in "$@"; do
      if [ "$argument" = commit ]; then
        printf 'staging\\n' > #{shell_quote(ready)}
        gate_attempts=0
        while [ ! -s #{shell_quote(release)} ]; do
          gate_attempts=$((gate_attempts + 1))
          [ "$gate_attempts" -le 3000 ] || exit 124
          sleep 0.01
        done
        IFS= read -r release < #{shell_quote(release)} || exit 125
        break
      fi
    done
    exec #{shell_quote(git)} "$@"
    """)

    File.chmod!(executable, 0o700)
    Application.put_env(:oh_my_jido_docs, :source_git_executable, executable)
    %{ready: ready, release: release}
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp managed_run(workspace, revision) do
    %Run{}
    |> Run.changeset(%{
      task: "Review source writer settlement",
      mode: "docs",
      session_id: Ecto.UUID.generate(),
      workspace: workspace,
      base_revision: revision,
      status: "completed"
    })
    |> Repo.insert!()
  end

  defp allocation_fixture(data, kind, id) do
    {parent, metadata} =
      case kind do
        "workspace" ->
          {Path.join(data, "workspaces"), Path.join(data, "workspace_metadata/#{id}.json")}

        "candidate" ->
          {Path.join(data, "candidates"), Path.join(data, "candidate_metadata/#{id}.json")}

        "source" ->
          {Path.join(data, "sources"), Path.join(data, "source/current.json")}
      end

    staging = Path.join(parent, ".staging-#{kind}-#{id}")

    record = %{
      "schema" => 1,
      "owner" => "OhMyJidoDocs.Workspaces",
      "data_dir" => data,
      "kind" => kind,
      "id" => id,
      "staging" => staging,
      "final" => Path.join(parent, id),
      "metadata" => metadata,
      "auxiliary" => if(kind == "source", do: [staging <> ".reviewed"], else: []),
      "lease" => Path.join(data, "source_allocations/#{kind}-#{id}.json")
    }

    File.write!(record["lease"], Jason.encode!(record))
    record
  end
end
