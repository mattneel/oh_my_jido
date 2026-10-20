defmodule OhMyJidoDocs.Editor.Host do
  @moduledoc """
  Trusted native host policy for the private editor.

  Context, mode, account and workspace are selected by the host, never by tool
  schemas. Docs runs can mutate only canonical paths below `priv/docs`; coding
  explicitly enables native Shell. Every subprocess, including Git and ripgrep,
  asks a fresh human approval. Shell is an approved OS capability, not a sandbox.
  Credentials are resolved only from this application's explicit configuration.
  Restored contexts bind through the fixed runtime, durable native session ID
  and canonical stored workspace. The Run supplies mode; optional metadata must
  agree with that authority and cannot grant a different identity or capability.
  Authorization and credential resolution also require the durable pending
  writer claim and its live holder, bound to this exact native coordinator PID.
  Losing the holder denies new effects/credentials without clearing source debt.
  """

  @behaviour OhMyJido.Host

  alias OhMyJido.{Context, Session, Workspace}
  alias OhMyJidoDocs.Editor.{Run, Snapshot, WriterLease}
  alias OhMyJidoDocs.Repo

  @runtime OhMyJidoDocs.Coding
  @git_reads [:repository_context, :status, :diff, :log, :commit_context]

  @impl true
  def authorize(context, capability, effect, _opts) do
    with {:ok, run} <- bound_run(context),
         true <- run.status in ["running", "waiting"],
         :ok <- scope(context, run, capability, effect) do
      if is_binary(Map.get(effect, :executable)) do
        {:approval,
         %{
           kind: :process,
           question:
             "Approve this one process effect? Approval does not authorize later processes.",
           effect:
             Snapshot.payload(
               Map.take(effect, [
                 :executable,
                 :args,
                 :cwd,
                 :operation,
                 :repository,
                 :paths,
                 :sensitive,
                 :mutates,
                 :phase,
                 :env
               ])
             )
         }}
      else
        :ok
      end
    else
      false -> {:error, :run_not_active}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def credentials(context, account, _opts) do
    with {:ok, _run} <- bound_run(context),
         true <- OhMyJido.Models.account_reference?(account),
         true <- account == Application.get_env(:oh_my_jido_docs, :model_account),
         key when is_binary(key) and byte_size(key) > 0 <-
           Application.get_env(:oh_my_jido_docs, :model_api_key) do
      {:ok, [api_key: key, auth_mode: :api_key]}
    else
      _unavailable -> {:error, :credentials_required}
    end
  end

  @impl true
  def question(_context, _question, _opts), do: :pending

  @impl true
  def invoke(_context, capability, _request, _opts),
    do: {:error, {:capability_unavailable, capability}}

  @doc false
  def register_secrets(session) do
    case Application.get_env(:oh_my_jido_docs, :model_api_key) do
      key when is_binary(key) and byte_size(key) > 0 -> Session.register_secrets(session, [key])
      _unconfigured -> :ok
    end
  end

  defp bound_run(
         %Context{
           runtime: @runtime,
           session_id: id,
           workspace: workspace,
           metadata: metadata
         } = context
       )
       when is_binary(id) and is_binary(workspace) and is_map(metadata) do
    with true <- Application.get_env(:oh_my_jido_docs, :editor_enabled, false),
         %Run{} = run <- Repo.get_by(Run, session_id: id),
         {:ok, canonical} <- Workspace.new(run.workspace),
         true <- canonical == workspace,
         true <- metadata_agrees?(metadata, run),
         true <- WriterLease.matches?(run, context) do
      {:ok, run}
    else
      _unbound -> {:error, :invalid_editor_context}
    end
  rescue
    _unavailable -> {:error, :invalid_editor_context}
  end

  defp bound_run(_context), do: {:error, :invalid_editor_context}

  defp metadata_agrees?(metadata, run) do
    Enum.all?(
      [
        {:docs_run_id, run.id},
        {"docs_run_id", run.id},
        {:docs_mode, run.mode},
        {"docs_mode", run.mode}
      ],
      fn {key, expected} ->
        not Map.has_key?(metadata, key) or Map.fetch!(metadata, key) == expected
      end
    )
  end

  defp scope(context, run, :edit, %{path: path}) do
    with {:ok, resolved} <- Workspace.resolve(context, path, allow_missing: true),
         relative when is_binary(relative) <- Workspace.relative(context, resolved),
         :ok <- source_path(relative) do
      if run.mode == "coding" or String.starts_with?(relative, "priv/docs/"),
        do: :ok,
        else: {:error, :docs_path_required}
    end
  end

  defp scope(_context, _run, :edit, _effect), do: {:error, :scoped_path_required}

  defp scope(_context, %{mode: "docs"}, :exec, _effect), do: {:error, :coding_mode_required}

  defp scope(_context, %{mode: "docs"}, :git, effect) do
    if Map.get(effect, :operation) in @git_reads and not Map.get(effect, :mutates, false),
      do: :ok,
      else: {:error, :docs_git_read_only}
  end

  defp scope(context, _run, :read, %{path: path}) do
    with {:ok, resolved} <- Workspace.resolve(context, path),
         relative when is_binary(relative) <- Workspace.relative(context, resolved),
         do: source_path(relative)
  end

  defp scope(_context, _run, capability, _effect) when capability in [:read, :git, :ask, :exec],
    do: :ok

  defp scope(_context, _run, _capability, _effect), do: {:error, :capability_not_authorized}

  defp source_path(relative) do
    parts = Path.split(relative)

    if Enum.any?(parts, fn part ->
         part == ".git" or part == ".env" or String.starts_with?(part, ".env.")
       end),
       do: {:error, :private_path},
       else: :ok
  end
end
