defmodule OhMyJido.Git do
  @moduledoc """
  Fixed Git workflows through the host-authorized subprocess boundary.

  Read operations require `:git`, not arbitrary `:exec`. Mutation also requires
  `:edit`. Commits explicitly select paths; both staging and committing are
  sensitive effects approved before execution. There are no history-rewriting,
  force-removal, publishing, remote or arbitrary-argument operations.

  Worktrees may be created and removed only under trusted
  `context.metadata.git_worktree_roots` (default: the workspace). Those roots
  must already exist. `isolate/3` refuses a dirty source and returns a clean,
  detached real worktree plus a context preserving the caller's grants. The
  returned context remembers its approved source repository's common Git root.

  Hooks, external diffs, text conversion and fsmonitor are disabled. Ambient Git
  directory/index/config overrides are removed only from each child environment.
  This policy is not an OS sandbox for a malicious repository configuration.
  Interrupted operations expose their process evidence and uncertain effects;
  none are retried or automatically rolled back.
  """

  alias OhMyJido.{Context, Workspace}
  alias OhMyJido.Process, as: Runner

  @git_options [
    "--no-pager",
    "--literal-pathspecs",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "commit.gpgSign=false",
    "-c",
    "core.quotePath=false",
    "-c",
    "diff.external=",
    "-c",
    "color.ui=false"
  ]
  @environment %{
    "GIT_CONFIG_NOSYSTEM" => "1",
    "GIT_CONFIG_GLOBAL" => "/dev/null",
    "GIT_TERMINAL_PROMPT" => "0",
    "GIT_OPTIONAL_LOCKS" => "0",
    "GIT_LITERAL_PATHSPECS" => "1",
    "GIT_DIR" => nil,
    "GIT_WORK_TREE" => nil,
    "GIT_COMMON_DIR" => nil,
    "GIT_INDEX_FILE" => nil,
    "GIT_OBJECT_DIRECTORY" => nil,
    "GIT_ALTERNATE_OBJECT_DIRECTORIES" => nil,
    "GIT_CONFIG" => nil,
    "GIT_CONFIG_COUNT" => nil,
    "GIT_CONFIG_PARAMETERS" => nil,
    "GIT_EXTERNAL_DIFF" => nil,
    "GIT_SSH" => nil,
    "GIT_SSH_COMMAND" => nil,
    "GIT_ASKPASS" => nil,
    "SSH_ASKPASS" => nil,
    "GIT_PAGER" => "cat",
    "LC_ALL" => "C"
  }

  @doc "Returns NUL-delimited porcelain entries and the exact process result."
  @spec status(map() | Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(execution_context, opts \\ []) do
    with {:ok, context, repo} <- repository(execution_context, opts),
         {:ok, result} <-
           command(
             context,
             repo,
             [
               "status",
               "--porcelain=v1",
               "-z",
               "--untracked-files=all",
               "--ignore-submodules=all"
             ],
             :status,
             opts
           ),
         :ok <- complete_output(result),
         {:ok, entries} <- status_entries(String.split(result.stdout, <<0>>, trim: true), []) do
      {:ok, Map.merge(result, %{entries: entries, clean: entries == []})}
    end
  end

  @doc "Returns a bounded real diff with optional staged/base/path and hunk context selection."
  @spec diff(map() | Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def diff(execution_context, opts \\ []) do
    with {:ok, context, repo} <- repository(execution_context, opts),
         {:ok, paths} <-
           selected_paths(%{context | workspace: repo}, Keyword.get(opts, :paths, [])),
         {:ok, base} <- optional_revision(Keyword.get(opts, :base)),
         context_lines when is_integer(context_lines) and context_lines in 0..100 <-
           Keyword.get(opts, :context_lines, 3) do
      staged = if Keyword.get(opts, :cached, false), do: ["--cached"], else: []

      args =
        [
          "diff",
          "--no-ext-diff",
          "--no-textconv",
          "--ignore-submodules=all",
          "--unified=#{context_lines}"
        ] ++ staged ++ base ++ ["--" | paths]

      command(context, repo, args, :diff, opts)
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_diff_context}
    end
  end

  @doc "Returns a bounded commit log without invoking a pager or external formatter."
  @spec log(map() | Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def log(execution_context, opts \\ []) do
    with {:ok, context, repo} <- repository(execution_context, opts),
         limit when is_integer(limit) and limit in 1..100 <- Keyword.get(opts, :limit, 20),
         {:ok, revision} <- optional_revision(Keyword.get(opts, :revision)) do
      command(
        context,
        repo,
        [
          "log",
          "--no-show-signature",
          "--format=%H%x00%P%x00%an%x00%aI%x00%s",
          "-n",
          Integer.to_string(limit)
        ] ++ revision ++ ["--"],
        :log,
        opts
      )
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_log_limit}
    end
  end

  @doc "Returns a real HEAD identity, workspace status and bounded patch together."
  @spec patch_context(map() | Context.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def patch_context(execution_context, opts \\ []) do
    with {:ok, context, repo} <- repository(execution_context, opts),
         {:ok, head} <- commit_id(context, repo, "HEAD", opts),
         {:ok, status} <- status(context, opts),
         {:ok, diff} <- diff(context, opts) do
      {:ok,
       %{
         head: head,
         status: status,
         diff: diff.stdout,
         stderr: diff.stderr,
         truncated: diff.truncated,
         process: diff
       }}
    end
  end

  @doc "Stages and commits only approved, explicit paths without including unrelated staged work."
  @spec commit(map() | Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def commit(execution_context, message, opts \\ []) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- mutation_grant(context),
         :ok <- valid_message(message),
         {:ok, context, repo} <- repository(context, opts),
         {:ok, paths} <-
           selected_paths(%{context | workspace: repo}, Keyword.get(opts, :paths, [])),
         true <- paths != [],
         {:ok, _staged} <-
           command(context, repo, ["add", "--" | paths], :commit, opts, %{
             sensitive: true,
             mutates: true,
             phase: :stage,
             message: message,
             paths: paths
           }),
         {:ok, result} <-
           command(
             context,
             repo,
             ["commit", "--only", "--no-gpg-sign", "-m", message, "--" | paths],
             :commit,
             opts,
             %{sensitive: true, mutates: true, phase: :commit, message: message, paths: paths}
           ) do
      case commit_id(context, repo, "HEAD", opts) do
        {:ok, head} ->
          {:ok, Map.merge(result, %{commit: head, paths: paths})}

        {:error, reason} ->
          {:error,
           %{
             reason: :commit_identity_unavailable,
             effect: :completed,
             process: result,
             observation_error: reason
           }}
      end
    else
      false -> {:error, :commit_paths_required}
      {:error, _reason} = error -> error
    end
  end

  @doc "Creates a real detached worktree at an absent approved path, pinned to a commit."
  @spec create_worktree(map() | Context.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_worktree(execution_context, path, opts \\ []) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- mutation_grant(context),
         {:ok, target} <- worktree_path(context, path, true),
         :ok <- absent_target(target),
         {:ok, context, repo} <- repository(context, opts),
         {:ok, [revision]} <- optional_revision(Keyword.get(opts, :revision, "HEAD")),
         {:ok, head} <- commit_id(context, repo, revision, opts),
         {:ok, result} <-
           command(
             context,
             repo,
             ["worktree", "add", "--detach", "--", target, head],
             :worktree_add,
             opts,
             %{mutates: true, path: target, revision: head}
           ) do
      {:ok, Map.merge(result, %{path: target, head: head})}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_git_revision}
    end
  end

  @doc "Refuses dirty work and removes only a registered worktree within approved roots."
  @spec remove_worktree(map() | Context.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def remove_worktree(execution_context, path, opts \\ []) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- mutation_grant(context),
         {:ok, target} <- worktree_path(context, path, false),
         {:ok, context, repo} <- repository(context, opts),
         true <- target != repo and target != source_root(context),
         :ok <- registered_worktree(context, repo, target, opts),
         child = child_context(context, target),
         {:ok, status} <- status(child, Keyword.delete(opts, :repo)),
         true <- status.clean,
         {:ok, result} <-
           command(context, repo, ["worktree", "remove", "--", target], :worktree_remove, opts, %{
             mutates: true,
             path: target
           }) do
      {:ok, Map.put(result, :path, target)}
    else
      false -> {:error, {:dirty_worktree, path}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns a clean, pinned worktree and a context suitable for a mutating subagent."
  @spec isolate(map() | Context.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def isolate(execution_context, child_id, opts \\ []) do
    with {:ok, context} <- Context.fetch(execution_context),
         :ok <- mutation_grant(context),
         {:ok, path} <- isolation_path(context, child_id, opts),
         {:ok, status} <- status(context, opts),
         true <- status.clean,
         {:ok, worktree} <- create_worktree(context, path, opts) do
      {:ok,
       worktree
       |> Map.delete(:path)
       |> Map.put(:workspace, worktree.path)
       |> Map.put(:repository_root, source_root(context))
       |> Map.put(:context, child_context(context, worktree.path))}
    else
      false -> {:error, {:dirty_repository, :uncommitted_changes}}
      {:error, _reason} = error -> error
    end
  end

  defp isolation_path(context, child_id, opts) when is_binary(child_id) do
    roots = Map.get(context.metadata, :git_worktree_roots, [context.workspace])

    with true <- Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, child_id),
         [root | _rest] <- roots,
         true <- is_binary(root) do
      {:ok, Keyword.get(opts, :path, Path.join(root, child_id))}
    else
      _invalid -> {:error, :invalid_worktree_isolation}
    end
  end

  defp isolation_path(_context, _child_id, _opts), do: {:error, :invalid_worktree_isolation}

  defp repository(execution_context, opts) do
    with {:ok, context} <- Context.fetch(execution_context),
         {:ok, repo} <- Workspace.resolve(context, Keyword.get(opts, :repo, ".")),
         true <- File.dir?(repo) and not String.contains?(repo, ["\n", "\r"]),
         {:ok, _directory} <- git_directory(context, repo),
         {:ok, result} <-
           command(
             context,
             repo,
             ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir"],
             :repository_context,
             opts
           ),
         :ok <- complete_output(result),
         [top, common] <- String.split(String.trim_trailing(result.stdout, "\n"), "\n"),
         {:ok, _top} <- Workspace.resolve(context, top),
         {:ok, _common} <- Workspace.resolve(%{context | workspace: source_root(context)}, common) do
      {:ok, context, top}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_git_repository}
    end
  end

  defp command(context, repo, args, operation, opts, metadata \\ %{}) do
    process_opts = Keyword.take(opts, [:timeout, :max_output_bytes, :on_output, :observer])
    effect = Map.merge(metadata, %{operation: operation, repository: repo})

    with {:ok, result} <-
           Runner.run(
             context,
             "git",
             @git_options ++ args,
             Keyword.merge(process_opts,
               cwd: repo,
               env: @environment,
               capability: :git,
               effect: effect,
               before_effect: fn -> git_precondition(context, repo, operation, metadata) end
             )
           ) do
      cond do
        result.status != :exited or result.effect == :uncertain ->
          {:error, {:uncertain_git_effect, result}}

        result.exit_status != 0 ->
          {:error, {:git_failed, result}}

        true ->
          {:ok, result}
      end
    end
  end

  defp git_precondition(context, repo, operation, metadata) do
    with {:ok, _directory} <- git_directory(context, repo) do
      git_operation_precondition(context, repo, operation, metadata)
    end
  end

  defp git_operation_precondition(context, repo, :commit, metadata) do
    case selected_paths(%{context | workspace: repo}, metadata.paths) do
      {:ok, _paths} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp git_operation_precondition(context, _repo, :worktree_add, metadata) do
    with {:ok, target} <- worktree_path(context, metadata.path, true),
         true <- target == metadata.path do
      absent_target(target)
    end
  end

  defp git_operation_precondition(context, _repo, :worktree_remove, metadata) do
    with {:ok, target} <- worktree_path(context, metadata.path, false),
         true <- target == metadata.path do
      :ok
    end
  end

  defp git_operation_precondition(_context, _repo, _operation, _metadata), do: :ok

  defp git_directory(context, directory) do
    marker = Path.join(directory, ".git")

    case File.lstat(marker) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= 4096 ->
        with {:ok, contents} <- File.read(marker),
             "gitdir: " <> target <- String.trim_trailing(contents, "\n"),
             {:ok, target} <-
               Workspace.resolve(
                 %{context | workspace: source_root(context)},
                 Path.expand(target, directory)
               ),
             true <- File.dir?(target),
             :ok <- worktree_binding(context, marker, target) do
          {:ok, target}
        else
          {:error, _reason} = error -> error
          _invalid -> {:error, :invalid_git_directory}
        end

      {:ok, %File.Stat{type: type}} when type in [:directory, :symlink] ->
        with {:ok, target} <-
               Workspace.resolve(%{context | workspace: source_root(context)}, marker),
             true <- File.dir?(target),
             true <- source_root(context) == context.workspace,
             do: {:ok, target}

      {:error, :enoent} when directory != context.workspace ->
        parent = Path.dirname(directory)

        with {:ok, _parent} <- Workspace.resolve(context, parent),
             do: git_directory(context, parent)

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_git_directory}
    end
  end

  defp worktree_binding(context, marker, directory) do
    if source_root(context) == context.workspace do
      :ok
    else
      with {:ok, backlink} <-
             Workspace.resolve(
               %{context | workspace: source_root(context)},
               Path.join(directory, "gitdir")
             ),
           {:ok, %File.Stat{type: :regular, size: size}} when size <= 4096 <- File.stat(backlink),
           {:ok, contents} <- File.read(backlink),
           {:ok, pointer} <- Workspace.resolve(context, String.trim_trailing(contents, "\n")),
           true <- pointer == marker do
        :ok
      else
        _unbound -> {:error, :invalid_worktree_binding}
      end
    end
  end

  defp mutation_grant(context) do
    if Context.permitted?(context, :edit), do: :ok, else: {:error, {:permission_denied, :edit}}
  end

  defp complete_output(%{truncated: true} = result), do: {:error, {:git_output_truncated, result}}
  defp complete_output(_result), do: :ok

  defp valid_message(message) when is_binary(message) do
    if String.trim(message) != "" and byte_size(message) <= 16_384 and
         not String.contains?(message, <<0>>), do: :ok, else: {:error, :invalid_commit_message}
  end

  defp valid_message(_message), do: {:error, :invalid_commit_message}

  defp selected_paths(context, paths) when is_list(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, selected} ->
      with {:ok, absolute} <- Workspace.resolve(context, path, allow_missing: true),
           false <- File.dir?(absolute),
           relative when is_binary(relative) <- Workspace.relative(context, path),
           false <- ".git" in Path.split(relative) do
        {:cont, {:ok, [relative | selected]}}
      else
        {:error, _reason} = error -> {:halt, error}
        _invalid -> {:halt, {:error, :invalid_git_path}}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  defp selected_paths(_context, _paths), do: {:error, :invalid_git_paths}

  defp optional_revision(nil), do: {:ok, []}

  defp optional_revision(revision) when is_binary(revision) do
    if revision != "" and byte_size(revision) <= 512 and not String.starts_with?(revision, "-") and
         not String.contains?(revision, [<<0>>, "\n", "\r"]),
       do: {:ok, [revision]},
       else: {:error, :invalid_git_revision}
  end

  defp optional_revision(_revision), do: {:error, :invalid_git_revision}

  defp commit_id(context, repo, revision, opts) do
    with {:ok, result} <-
           command(
             context,
             repo,
             ["rev-parse", "--verify", "--end-of-options", revision <> "^{commit}"],
             :commit_context,
             opts
           ),
         :ok <- complete_output(result),
         hash = String.trim(result.stdout),
         true <- Regex.match?(~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/, hash) do
      {:ok, hash}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_git_commit_identity}
    end
  end

  defp status_entries([], entries), do: {:ok, Enum.reverse(entries)}

  defp status_entries([<<index, worktree, 32, path::binary>> | rest], entries) do
    if index in [?R, ?C] or worktree in [?R, ?C] do
      case rest do
        [original | rest] ->
          status_entries(rest, [
            %{index: <<index>>, worktree: <<worktree>>, path: path, original_path: original}
            | entries
          ])

        _missing ->
          {:error, :invalid_git_status}
      end
    else
      status_entries(rest, [%{index: <<index>>, worktree: <<worktree>>, path: path} | entries])
    end
  end

  defp status_entries(_invalid, _entries), do: {:error, :invalid_git_status}

  defp worktree_path(context, path, missing) when is_binary(path) do
    roots = Map.get(context.metadata, :git_worktree_roots, [context.workspace])
    absolute = Path.expand(path, context.workspace)

    worktree_path_in_roots(context, roots, absolute, missing)
  end

  defp worktree_path(_context, _path, _missing), do: {:error, :invalid_worktree_path}

  defp worktree_path_in_roots(context, roots, absolute, missing) when is_list(roots) do
    Enum.reduce_while(roots, {:error, :outside_worktree_roots}, fn root, _error ->
      with {:ok, root} <- Workspace.new(root),
           {:ok, target} <-
             Workspace.resolve(%{context | workspace: root}, absolute, allow_missing: missing),
           true <- target != root and not String.contains?(target, ["\n", "\r"]) do
        {:halt, {:ok, target}}
      else
        _denied -> {:cont, {:error, :outside_worktree_roots}}
      end
    end)
  end

  defp worktree_path_in_roots(_context, _roots, _absolute, _missing),
    do: {:error, :invalid_worktree_roots}

  defp absent_target(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :worktree_target_exists}
      {:error, reason} -> {:error, reason}
    end
  end

  defp registered_worktree(context, repo, target, opts) do
    with {:ok, result} <-
           command(
             context,
             repo,
             ["worktree", "list", "--porcelain", "-z"],
             :worktree_context,
             opts
           ),
         :ok <- complete_output(result) do
      paths = for "worktree " <> path <- String.split(result.stdout, <<0>>), do: path
      if target in paths, do: :ok, else: {:error, :unregistered_worktree}
    end
  end

  defp source_root(context),
    do: Map.get(context.metadata, :git_repository_root, context.workspace)

  defp child_context(context, path) do
    metadata =
      context.metadata
      |> Map.put(:git_repository_root, source_root(context))
      |> Map.put(:git_worktree_roots, [path])

    %{context | workspace: path, metadata: metadata}
  end
end
