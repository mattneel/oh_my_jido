defmodule OhMyJido.GitTest do
  use ExUnit.Case, async: true

  alias OhMyJido.{Context, Git, Tool}

  defmodule Policy do
    def authorize(_context, capability, effect, opts) do
      send(opts[:observer], {:authorization, capability, effect})

      cond do
        opts[:deny_git] == true and capability == :git ->
          {:error, :git_denied}

        effect[:sensitive] == true and opts[:approve_sensitive] != true ->
          {:error, :sensitive_denied}

        true ->
          :ok
      end
    end
  end

  setup do
    root = Path.join(System.tmp_dir!(), "omj-git-#{System.unique_integer([:positive])}")
    repo = Path.join(root, "repo")
    trees = Path.join(root, "worktrees")
    File.mkdir_p!(repo)
    File.mkdir_p!(trees)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(repo, ["init", "--quiet"])
    git!(repo, ["config", "user.name", "Fixture User"])
    git!(repo, ["config", "user.email", "fixture@example.test"])
    File.write!(Path.join(repo, "tracked.txt"), "original\n")
    File.write!(Path.join(repo, "other.txt"), "unchanged\n")
    git!(repo, ["add", "--", "tracked.txt", "other.txt"])
    git!(repo, ["-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "initial"])

    context = %Context{
      session_id: "git-test",
      workspace: repo,
      permissions: MapSet.new([:git, :edit]),
      host: {Policy, observer: self()},
      metadata: %{git_worktree_roots: [trees]},
      tools: [OhMyJido.Tools.Git]
    }

    %{root: root, repo: repo, trees: trees, context: context}
  end

  test "status, diff, log and patch context observe actual disposable repository content", %{
    repo: repo,
    context: context
  } do
    assert {:ok, %{clean: true, exit_status: 0}} = Git.status(context)
    File.write!(Path.join(repo, "tracked.txt"), "changed\n")
    assert {:ok, %{clean: false, entries: entries}} = Git.status(context)
    assert Enum.any?(entries, &(&1.path == "tracked.txt"))
    assert {:ok, %{stdout: diff, exit_status: 0}} = Git.diff(context)
    assert diff =~ "-original"
    assert diff =~ "+changed"
    assert {:ok, %{stdout: history}} = Git.log(context, limit: 1)
    assert history =~ "initial"
    assert {:ok, %{diff: patch, status: %{clean: false}, head: head}} = Git.patch_context(context)
    assert patch == diff
    assert head == String.trim(git!(repo, ["rev-parse", "HEAD"]))
    assert {:ok, %{clean: false}} = Tool.execute(context, "git", %{operation: "status"})
  end

  test "commit approval occurs before staging and commits only explicitly selected paths", %{
    repo: repo,
    context: context
  } do
    before = String.trim(git!(repo, ["rev-parse", "HEAD"]))
    File.write!(Path.join(repo, "tracked.txt"), "new tracked content\n")
    File.write!(Path.join(repo, "new.txt"), "new file\n")
    File.write!(Path.join(repo, "other.txt"), "unrelated staged content\n")
    git!(repo, ["add", "--", "other.txt"])

    assert {:error, :sensitive_denied} =
             Git.commit(context, "target change", paths: ["tracked.txt", "new.txt"])

    assert String.trim(git!(repo, ["rev-parse", "HEAD"])) == before
    refute git!(repo, ["diff", "--cached", "--name-only"]) =~ "tracked.txt"

    assert_receive {:authorization, :git,
                    %{operation: :commit, sensitive: true, paths: ["tracked.txt", "new.txt"]}}

    approved = %{context | host: {Policy, observer: self(), approve_sensitive: true}}

    assert {:ok, %{commit: commit, effect: :completed, exit_status: 0}} =
             Git.commit(approved, "target change", paths: ["tracked.txt", "new.txt"])

    assert commit != before
    assert String.trim(git!(repo, ["rev-parse", "HEAD"])) == commit
    assert git!(repo, ["show", "HEAD:tracked.txt"]) == "new tracked content\n"
    assert git!(repo, ["show", "HEAD:new.txt"]) == "new file\n"
    assert git!(repo, ["show", "HEAD:other.txt"]) == "unchanged\n"
    assert git!(repo, ["diff", "--cached", "--name-only"]) =~ "other.txt"
  end

  test "clean worktree isolation creates real detached targets and removal refuses dirty work", %{
    repo: repo,
    trees: trees,
    context: context
  } do
    target = Path.join(trees, "child")

    assert {:ok, %{context: child_context, workspace: ^target, head: head}} =
             Git.isolate(context, "child", path: target)

    assert child_context.workspace == target
    assert child_context.permissions == context.permissions
    assert child_context.metadata.git_worktree_roots == [target]
    sibling = Path.join(trees, "sibling")
    assert {:ok, %{exit_status: 0}} = Git.create_worktree(context, sibling)
    assert {:error, :outside_worktree_roots} = Git.remove_worktree(child_context, sibling)
    assert File.exists?(Path.join(sibling, "tracked.txt"))
    assert {:ok, %{exit_status: 0}} = Git.remove_worktree(context, sibling)
    assert File.read!(Path.join(target, "tracked.txt")) == "original\n"
    assert String.trim(git!(target, ["rev-parse", "HEAD"])) == head
    assert {:ok, %{clean: true}} = Git.status(child_context)
    File.write!(Path.join(target, "tracked.txt"), "child edit\n")
    assert File.read!(Path.join(repo, "tracked.txt")) == "original\n"
    assert {:error, {:dirty_worktree, _}} = Git.remove_worktree(context, target)
    File.write!(Path.join(target, "tracked.txt"), "original\n")
    assert {:ok, %{path: ^target, exit_status: 0}} = Git.remove_worktree(context, target)
    refute File.exists?(target)
    refute git!(repo, ["worktree", "list", "--porcelain"]) =~ target
  end

  test "worktree boundaries and symlink escapes fail before creating any target", %{
    root: root,
    trees: trees,
    context: context
  } do
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(trees, "escape"))
    assert {:error, _} = Git.create_worktree(context, Path.join(outside, "denied"))
    assert {:error, _} = Git.create_worktree(context, Path.join(trees, "escape/denied"))
    refute File.exists?(Path.join(outside, "denied"))
  end

  test "a Git file pointing outside the approved repository root is rejected before launch", %{
    root: root,
    context: context
  } do
    fake = Path.join(root, "fake")
    File.mkdir_p!(fake)
    File.write!(Path.join(fake, ".git"), "gitdir: #{Path.join(context.workspace, ".git")}\n")
    assert {:error, _} = Git.status(%{context | workspace: fake})
    refute_receive {:authorization, :git, _effect}
  end

  test "isolation chooses a stable approved root and returns source metadata for narrowed children",
       %{trees: trees, context: context} do
    target = Path.join(trees, "default-child")

    assert {:ok, %{workspace: ^target, repository_root: source}} =
             Git.isolate(context, "default-child")

    assert source == context.workspace
    assert {:ok, %{exit_status: 0}} = Git.remove_worktree(context, target)
    assert {:error, :invalid_worktree_isolation} = Git.isolate(context, "../escape")
  end

  test "a child cannot redirect its Git marker to the parent's main index and branch", %{
    repo: repo,
    trees: trees,
    context: context
  } do
    target = Path.join(trees, "bound-child")
    assert {:ok, %{context: child}} = Git.isolate(context, "bound-child", path: target)
    marker = Path.join(target, ".git")
    original_marker = File.read!(marker)
    before = git!(repo, ["rev-parse", "HEAD"])
    File.write!(marker, "gitdir: #{Path.join(repo, ".git")}\n")
    assert {:error, _} = Git.status(child)
    assert git!(repo, ["rev-parse", "HEAD"]) == before
    File.write!(marker, original_marker)
    assert {:ok, %{exit_status: 0}} = Git.remove_worktree(context, target)
  end

  test "dirty source repositories cannot silently become a different clean subagent baseline", %{
    repo: repo,
    trees: trees,
    context: context
  } do
    File.write!(Path.join(repo, "tracked.txt"), "not committed\n")

    assert {:error, {:dirty_repository, _}} =
             Git.isolate(context, "child", path: Path.join(trees, "child"))

    refute File.exists?(Path.join(trees, "child"))
  end

  test "read-only Git authority does not grant arbitrary execution or mutation", %{
    context: context
  } do
    assert {:error, {:permission_denied, :git}} =
             Git.status(%{context | permissions: MapSet.new([:exec])})

    reader = %{
      context
      | permissions: MapSet.new([:git]),
        tools: [OhMyJido.Tools.Git, OhMyJido.Tools.Shell]
    }

    assert {:ok, %{clean: true}} = Git.status(reader)

    assert {:error, :git_denied} =
             Git.status(%{reader | host: {Policy, observer: self(), deny_git: true}})

    assert {:error, {:permission_denied, :edit}} =
             Git.commit(reader, "denied", paths: ["tracked.txt"])

    assert {:error, _} =
             Tool.execute(reader, "shell", %{executable: "printf", args: ["forbidden"]})

    assert {:error, _} = Tool.execute(context, "git", %{operation: "reset", args: ["--hard"]})
  end

  test "paths beginning with Git magic are interpreted literally and cannot escape the workspace",
       %{repo: repo, context: context} do
    approved = %{context | host: {Policy, observer: self(), approve_sensitive: true}}
    File.write!(Path.join(repo, ":(glob)*"), "literal path\n")
    assert {:ok, %{exit_status: 0}} = Git.commit(approved, "literal", paths: [":(glob)*"])
    assert git!(repo, ["show", "HEAD::(glob)*"]) == "literal path\n"
    assert {:error, _} = Git.commit(approved, "escape", paths: ["../other"])
  end

  defp git!(cwd, args) do
    env = %{
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_OPTIONAL_LOCKS" => "0"
    }

    case System.cmd("git", args, cd: cwd, env: env, stderr_to_stdout: true) do
      {stdout, 0} -> stdout
      {output, status} -> flunk("fixture Git command failed (#{status}): #{output}")
    end
  end
end
