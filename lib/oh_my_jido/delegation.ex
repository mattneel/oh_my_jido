defmodule OhMyJido.Delegation do
  @moduledoc """
  Distinct coding tasks under Jido's native parent/child hierarchy.

  Children receive a subset of their parent's grants. Read-only tasks share the
  repository; writes require a separate host-granted workspace or a Git worktree.
  Native Jido adoption binds lifecycle ownership; no second agent scheduler exists.
  """

  alias OhMyJido.{Context, Runtime, Session, SessionRef, Tool, Workspace}

  @read_grants [
    :read,
    :git,
    :ast,
    :lsp,
    :observe,
    :artifact,
    :review,
    :memory,
    :planning,
    :skills,
    :ask,
    :research
  ]

  @doc "Starts one bounded task with a narrowed context and real Jido child."
  @spec start(SessionRef.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(parent, task, opts \\ []) do
    with {:ok, context} <- Session.call(parent, :context),
         :ok <-
           Tool.authorize(context, :delegate, %{
             task: task,
             role: Keyword.get(opts, :role, :exploration)
           }),
         {:ok, permissions} <- child_permissions(context, opts),
         :ok <- depth_allowed(context),
         {:ok, tag} <- child_tag(opts),
         id <- "child-" <> Jido.Util.generate_id(),
         {:ok, workspace} <- child_workspace(context, id, permissions, opts) do
      start_child(parent, context, id, tag, workspace, permissions, task, opts)
    end
  end

  @doc "Waits for a child's structured result; does not cancel on caller timeout."
  def await(parent, tag, opts \\ []) do
    with {:ok, child} <- child(parent, tag) do
      OhMyJido.await(child.session, child.run, opts)
    end
  end

  @doc "Queues steering on a tracked child's existing run."
  def steer(parent, tag, text) do
    with {:ok, child} <- child(parent, tag), do: OhMyJido.steer(child.session, child.run, text)
  end

  @doc "Cancels a child run, leaving the parent session usable."
  def cancel(parent, tag) do
    with {:ok, child} <- child(parent, tag), do: OhMyJido.cancel(child.session, child.run)
  end

  defp start_child(parent, context, id, tag, workspace, permissions, task, opts) do
    with {:ok, lease} <- Runtime.reserve(parent.runtime, :subagent, context.coordinator) do
      metadata =
        context.metadata
        |> Map.drop([:runtime_config, :task_metadata, :eval])
        |> Map.put(:delegation_depth, Map.get(context.metadata, :delegation_depth, 0) + 1)
        |> Map.put(:git_repository_root, workspace.repository_root)
        |> Map.put(:git_worktree_roots, [workspace.workspace])
        |> Map.put(:delegation_roots, [])

      child_opts = [
        id: id,
        workspace: workspace.workspace,
        permissions: MapSet.to_list(permissions),
        role: Keyword.get(opts, :role, :exploration),
        account: context.account,
        tools: context.tools,
        host: context.host,
        adapters: context.adapters,
        metadata: metadata
      ]

      result =
        case Runtime.start_session(parent.runtime, child_opts) do
          {:ok, ref} ->
            start_child_run(parent, ref, tag, task, opts, lease)

          {:error, _reason} = error ->
            error
        end

      case result do
        {:ok, _child} = ok ->
          ok

        {:error, _reason} = error ->
          Runtime.release(lease)
          error
      end
    end
  end

  defp start_child_run(parent, ref, tag, task, opts, lease) do
    result =
      with {:ok, child_context} <- Session.call(ref, :context),
           {:ok, %{agent_pid: agent}} <- OhMyJido.inspect_session(ref),
           :ok <- Session.call(parent, {:adopt, agent, tag, ref, lease}),
           prompt_opts <- Keyword.take(opts, [:llm_opts, :req_http_options, :max_iterations]),
           {:ok, run_id} <- OhMyJido.prompt(ref, task, prompt_opts),
           :ok <- Session.call(parent, {:child_started, tag, ref, run_id}),
           {:ok, _collector} <- collect_child(parent, tag, ref, run_id) do
        {:ok,
         %{
           tag: tag,
           session: ref,
           run: run_id,
           workspace: child_context.workspace,
           role: child_context.role
         }}
      end

    if match?({:error, _reason}, result) do
      OhMyJido.stop_session(ref)
      Session.call(parent, {:child_start_failed, tag, ref})
    end

    result
  end

  defp child_permissions(context, opts) do
    writable = Keyword.get(opts, :writable, false)

    requested =
      Keyword.get(
        opts,
        :permissions,
        if(writable, do: MapSet.to_list(context.permissions), else: @read_grants)
      )

    if is_list(requested) and Enum.all?(requested, &is_atom/1) do
      validate_child_permissions(context, MapSet.new(requested), writable, opts)
    else
      {:error, :invalid_child_permissions}
    end
  end

  defp validate_child_permissions(context, permissions, writable, opts) do
    cond do
      not MapSet.subset?(permissions, context.permissions) and
          Keyword.has_key?(opts, :permissions) ->
        {:error, :permission_escalation}

      not writable and Keyword.has_key?(opts, :permissions) and
          not MapSet.subset?(permissions, MapSet.new(@read_grants)) ->
        {:error, :read_only_child}

      writable and not Context.permitted?(context, :edit) ->
        {:error, {:permission_denied, :edit}}

      true ->
        {:ok, narrow_child_permissions(context, permissions, writable)}
    end
  end

  defp narrow_child_permissions(context, permissions, writable) do
    permissions =
      MapSet.intersection(permissions, context.permissions) |> MapSet.delete(:delegate)

    if writable,
      do: permissions,
      else: MapSet.intersection(permissions, MapSet.new(@read_grants))
  end

  defp depth_allowed(context) do
    if Map.get(context.metadata, :delegation_depth, 0) <
         Map.get(context.limits, :max_subagent_depth, 2),
       do: :ok,
       else: {:error, :delegation_depth}
  end

  defp child_tag(opts) do
    case Keyword.get_lazy(opts, :tag, &Jido.Util.generate_id/0) do
      tag when is_binary(tag) and byte_size(tag) in 1..96 -> {:ok, tag}
      _tag -> {:error, :invalid_child_tag}
    end
  end

  defp child_workspace(context, id, permissions, opts) do
    if MapSet.member?(permissions, :edit) or MapSet.member?(permissions, :exec) or
         MapSet.member?(permissions, :custom) do
      mutating_workspace(context, id, opts)
    else
      {:ok,
       %{
         workspace: context.workspace,
         repository_root: Map.get(context.metadata, :git_repository_root, context.workspace)
       }}
    end
  end

  defp mutating_workspace(context, id, opts) do
    case Keyword.get(opts, :workspace) do
      nil ->
        with {:ok, isolated} <- OhMyJido.Git.isolate(context, id, []) do
          {:ok, %{workspace: isolated.workspace, repository_root: isolated.repository_root}}
        end

      path ->
        declared_workspace(context, path)
    end
  end

  defp declared_workspace(context, path) do
    with {:ok, root} <- Workspace.new(path),
         roots <- Map.get(context.metadata, :delegation_roots, []),
         true <- root != context.workspace and root in roots,
         :ok <- Tool.authorize(context, :delegate, %{workspace: root, mutates: true}) do
      {:ok, %{workspace: root, repository_root: root}}
    else
      false -> {:error, :child_workspace_not_granted}
      {:error, _reason} = error -> error
    end
  end

  defp child(parent, tag) do
    with {:ok, snapshot} <- OhMyJido.inspect_session(parent) do
      case Map.fetch(snapshot.children, tag) do
        {:ok, %{run: nil}} -> {:error, :child_starting}
        {:ok, child} -> {:ok, restore_child_ref(child)}
        :error -> {:error, :unknown_child}
      end
    end
  end

  defp restore_child_ref(%{session: %SessionRef{}} = child), do: child

  defp restore_child_ref(%{session: %{runtime: runtime, id: id}} = child),
    do: %{child | session: %SessionRef{runtime: runtime, id: id}}

  defp collect_child(parent, tag, ref, run_id) do
    Task.Supervisor.start_child(Jido.task_supervisor_name(Runtime.engine(parent.runtime)), fn ->
      result = OhMyJido.await(ref, run_id, timeout: 3_600_000)
      Session.call(parent, {:child_result, tag, ref, run_id, result})
    end)
  end
end
