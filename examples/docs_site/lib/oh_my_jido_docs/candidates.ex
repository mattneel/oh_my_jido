defmodule OhMyJidoDocs.Candidates do
  @moduledoc """
  Source-first review, isolated child checks, previews, and explicitly approved effects.

  Candidate source identities never change. Check/build/preview processes only use private
  copies, and authored modules are never compiled or loaded in this editor VM. This context
  is unavailable in the public-only deployment. Deployment configuration is read only by an
  explicit `deploy/2` call; no ambient Fly credentials are discovered.
  """

  import Ecto.Query, only: [from: 2]

  alias OhMyJidoDocs.Candidates.{Candidate, Manager, Source}
  alias OhMyJidoDocs.{Content, Editor, Repo, Workspaces}

  def child_specs do
    if enabled?(), do: [Supervisor.child_spec({Manager, []}, shutdown: 20_000)], else: []
  end

  def enabled?, do: Application.get_env(:oh_my_jido_docs, :editor_enabled, false) == true

  def list(run_id) do
    if enabled?() do
      Repo.all(from c in Candidate, where: c.run_id == ^run_id, order_by: [desc: c.inserted_at])
    else
      []
    end
  end

  def get!(id) do
    if enabled?(), do: Repo.get!(Candidate, id), else: raise("private editor is disabled")
  end

  def prepare(run_id) do
    with :ok <- ensure_enabled() do
      locked("run:" <> run_id, fn -> prepare_candidate(run_id) end)
    end
  end

  def start_check(id), do: manager_call({:start, :check, id})
  def cancel_check(id), do: manager_call({:stop, :check, id})
  def start_preview(id), do: manager_call({:start, :preview, id})
  def stop_preview(id), do: manager_call({:stop, :preview, id})

  @doc "Resolves a live owned preview, optionally bound to an exact signed-capability digest and attempt."
  def preview_target(id, opts \\ []) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: manager_call({:preview_target, id, opts}),
      else: {:error, :preview_unavailable}
  end

  def deploy(id, digest), do: manager_call({:deploy, id, digest})
  def cancel_deploy(id), do: manager_call({:stop, :deploy, id})

  @doc "Retries identity-checked cleanup of a blocked global process lease; never force-clears unknown ownership."
  def reconcile_process_cleanup, do: manager_call(:reconcile_process_cleanup)

  def approve(id, digest) do
    with_candidate(id, fn candidate ->
      with :ok <- effect_available(candidate),
           :ok <- reviewed_source(candidate, digest),
           :ok <- checked(candidate) do
        update(candidate, %{
          approval_digest: digest,
          approved_at: DateTime.utc_now(),
          status: "approved"
        })
      end
    end)
  end

  def publish(id, digest) do
    with_reviewed_candidate(id, &publish_reviewed_candidate(&1, digest))
  end

  def adopt(id, digest) do
    with_reviewed_candidate(id, fn candidate ->
      with :ok <- authorized(candidate, digest) do
        ensure_adopted(candidate)
      end
    end)
  end

  @doc false
  def with_candidate(id, function) do
    with :ok <- ensure_enabled() do
      locked(id, fn -> function.(Repo.get!(Candidate, id)) end)
    end
  end

  @doc false
  def reviewed_source(candidate, digest) do
    with true <- is_binary(digest) and digest == candidate.digest,
         true <- Source.digest(candidate.manifest) == digest,
         :ok <- Source.verify(candidate.source_path, candidate.manifest, readonly: true),
         :ok <- Workspaces.verify_workspace(candidate.workspace_path, candidate.workspace_digest) do
      :ok
    else
      false -> {:error, :stale_digest}
      {:error, _} = error -> error
    end
  end

  @doc false
  def checked(%{check_status: "passed", check_digest: digest, digest: digest}), do: :ok
  def checked(_), do: {:error, :checks_required}

  @doc false
  def authorized(candidate, digest) do
    with :ok <- Editor.source_write_settled(candidate.workspace_path),
         :ok <- effect_available(candidate),
         :ok <- approved_source(candidate, digest) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  @doc false
  def effect_available(candidate) do
    if candidate.adoption_status in ["adopting", "uncertain"] or
         candidate.publication_receipt["status"] in ["pending", "uncertain"] do
      {:error, :source_effect_outcome_uncertain}
    else
      :ok
    end
  end

  @doc false
  def verify_effect_base(candidate, opts \\ []) do
    if candidate.adoption_status == "adopted" do
      verify_adopted_base(candidate, opts)
    else
      Workspaces.verify_base(candidate.source_root, candidate.base_manifest)
    end
  end

  @doc false
  def update(candidate, attrs) do
    case Repo.update(Candidate.effect_changeset(candidate, attrs)) do
      {:ok, candidate} = result ->
        notify(candidate)
        result

      error ->
        error
    end
  end

  @doc false
  def notify(candidate) do
    Phoenix.PubSub.broadcast(
      OhMyJidoDocs.PubSub,
      "docs-run:" <> candidate.run_id,
      {:docs_run_updated, candidate.run_id}
    )
  end

  defp prepare_candidate(run_id) do
    run = Editor.get_run!(run_id)
    candidate_id = Ecto.UUID.generate()

    with :ok <-
           require_condition(
             is_binary(run.workspace) and is_binary(run.base_revision),
             :workspace_unavailable
           ),
         :ok <-
           require_condition(
             length(list(run_id)) <
               Application.get_env(:oh_my_jido_docs, :candidate_limit_per_run, 12),
             :candidate_limit
           ),
         {:ok, published_digest} <- published_digest(),
         {:ok, snapshot} <- Workspaces.freeze(run.workspace, candidate_id),
         :ok <-
           require_condition(
             snapshot.base_revision == run.base_revision,
             :workspace_base_conflict
           ),
         :ok <- require_condition(snapshot.changed_paths != [], :no_changes) do
      attrs =
        Map.take(snapshot, [
          :digest,
          :source_path,
          :app_relative,
          :source_root,
          :base_root,
          :base_revision,
          :workspace_digest,
          :manifest,
          :base_manifest,
          :changed_paths,
          :diff
        ])
        |> Map.merge(%{
          run_id: run_id,
          workspace_path: run.workspace,
          published_base_digest: published_digest
        })

      case Repo.insert(Candidate.create_changeset(%Candidate{id: candidate_id}, attrs)) do
        {:ok, candidate} = result ->
          notify(candidate)
          result

        error ->
          error
      end
    else
      {:error, _} = error -> error
    end
  end

  defp publish_reviewed_candidate(candidate, digest) do
    with :ok <- authorized(candidate, digest),
         :ok <- docs_only(candidate),
         :ok <- require_condition(is_nil(candidate.publication_digest), :already_published),
         {:ok, candidate} <- ensure_adopted(candidate),
         :ok <- Editor.source_write_settled(candidate.workspace_path),
         :ok <- authorized(candidate, digest),
         :ok <- verify_effect_base(candidate),
         source_docs = Path.join([candidate.source_path, candidate.app_relative, "priv", "docs"]),
         {:ok, candidate} <-
           update(candidate, %{
             status: "publishing",
             publication_receipt: %{
               "status" => "pending",
               "candidate_digest" => digest,
               "previous_digest" => candidate.published_base_digest,
               "adopted_source_digest" => candidate.adoption_receipt["digest"],
               "started_at" => timestamp()
             }
           }) do
      complete_publication(candidate, digest, source_docs)
    end
  end

  defp complete_publication(candidate, digest, source_docs) do
    case Content.publish_directory(source_docs, candidate.published_base_digest, fn ->
           authorize_publication_commit(candidate, digest)
         end) do
      {:ok, published_digest} ->
        update(candidate, %{
          status: "published",
          publication_digest: published_digest,
          publication_receipt:
            Map.merge(candidate.publication_receipt, %{
              "status" => "published",
              "published_digest" => published_digest,
              "published_at" => timestamp()
            })
        })

      {:error, reason} = error ->
        attrs = %{
          status: "adopted",
          publication_receipt:
            Map.merge(candidate.publication_receipt, %{
              "status" => "failed",
              "source_remains_adopted" => true,
              "reason" => inspect(reason, limit: 10, printable_limit: 512)
            })
        }

        update_failed_effect(candidate, attrs, error)
    end
  end

  defp verify_adopted_base(candidate, opts) do
    with {:ok, source} <- Workspaces.current_source(),
         true <- source.source_root == candidate.adoption_receipt["source_root"],
         true <- source.digest == candidate.adoption_receipt["digest"],
         true <- candidate.adoption_receipt["candidate_digest"] == candidate.digest do
      if Keyword.get(opts, :deployment, false) and source.digest != candidate.digest,
        do: {:error, :adopted_source_requires_new_review},
        else: :ok
    else
      false -> {:error, :base_conflict}
      {:error, _} = error -> error
    end
  end

  defp docs_only(candidate) do
    prefix = Path.join([candidate.app_relative, "priv", "docs"]) <> "/"

    if Enum.all?(candidate.changed_paths, fn path ->
         String.starts_with?(path, prefix) and String.ends_with?(path, ".md")
       end) do
      :ok
    else
      {:error, :code_deployment_required}
    end
  end

  defp manager_call(message) do
    with :ok <- ensure_enabled(),
         pid when is_pid(pid) <- Process.whereis(Manager) do
      GenServer.call(pid, message, 30_000)
    else
      nil -> {:error, :candidate_owner_unavailable}
      {:error, _} = error -> error
    end
  end

  defp published_digest do
    case Content.current_digest() do
      digest when is_binary(digest) -> {:ok, digest}
      _ -> {:error, :published_content_uninitialized}
    end
  end

  defp ensure_adopted(%{adoption_status: "adopted"} = candidate) do
    with :ok <- verify_effect_base(candidate), do: {:ok, candidate}
  end

  defp ensure_adopted(candidate) do
    with :ok <- effect_available(candidate),
         {:ok, candidate} <-
           update(candidate, %{
             status: "adopting",
             adoption_status: "adopting",
             adoption_receipt: %{
               "status" => "pending",
               "candidate_digest" => candidate.digest,
               "started_at" => timestamp()
             }
           }) do
      case Workspaces.adopt(Map.from_struct(candidate)) do
        {:ok, receipt} ->
          update(candidate, %{
            status: "adopted",
            adoption_status: "adopted",
            adoption_receipt: Map.put(receipt, "status", "adopted")
          })

        {:error, reason} = error ->
          attrs = %{
            status: "approved",
            adoption_status: "failed",
            adoption_receipt:
              Map.merge(candidate.adoption_receipt, %{
                "status" => "failed",
                "reason" => inspect(reason, limit: 10, printable_limit: 512)
              })
          }

          update_failed_effect(candidate, attrs, error)
      end
    end
  end

  defp update_failed_effect(candidate, attrs, error) do
    case update(candidate, attrs) do
      {:ok, _} -> error
      update_error -> update_error
    end
  end

  defp authorize_publication_commit(pending, digest) do
    # The caller still owns the candidate, workspace and canonical-source locks.
    # Fetch directly rather than nesting the non-reentrant candidate lock.
    with %Candidate{} = current <- Repo.get(Candidate, pending.id),
         true <- current.status == "publishing" and is_nil(current.publication_digest),
         true <- current.publication_receipt == pending.publication_receipt,
         true <-
           current.adoption_status == "adopted" and
             current.adoption_receipt == pending.adoption_receipt,
         :ok <- Editor.source_write_settled(current.workspace_path),
         :ok <- approved_source(current, digest),
         :ok <- verify_effect_base(current) do
      :ok
    else
      nil -> {:error, :not_found}
      false -> {:error, :publication_authorization_changed}
      {:error, _} = error -> error
    end
  end

  defp approved_source(candidate, digest) do
    with :ok <- reviewed_source(candidate, digest),
         :ok <- checked(candidate),
         true <- candidate.approval_digest == digest do
      :ok
    else
      false -> {:error, :approval_required}
      {:error, _} = error -> error
    end
  end

  defp with_reviewed_candidate(id, function) do
    with_candidate(id, fn candidate ->
      with_reviewed_workspace(candidate, function)
    end)
  end

  defp with_reviewed_workspace(candidate, function) do
    Workspaces.with_workspace_lease(candidate.workspace_path, fn ->
      Workspaces.with_source_lock(fn -> function.(candidate) end)
    end)
  end

  defp require_condition(true, _reason), do: :ok
  defp require_condition(false, reason), do: {:error, reason}
  defp timestamp, do: DateTime.to_iso8601(DateTime.utc_now())

  defp ensure_enabled do
    if enabled?(), do: :ok, else: {:error, :editor_unavailable}
  end

  defp locked(resource, function) do
    :global.trans({{__MODULE__, resource}, self()}, function)
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.Query.CastError -> {:error, :invalid_id}
    Ecto.StaleEntryError -> {:error, :candidate_conflict}
  end
end
