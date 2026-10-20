defmodule OhMyJidoDocs.Editor.Store do
  @moduledoc false

  import Ecto.Query

  alias OhMyJidoDocs.{Editor, Repo}
  alias OhMyJidoDocs.Editor.{Run, RunEvent, Snapshot}

  @active ~w(queued running waiting cancelling suspending)

  def active_statuses, do: @active

  def active_runs do
    Repo.all(from r in Run, where: r.status in ^@active, order_by: [asc: r.inserted_at])
  end

  # SQLite's map dumper clears to JSON null, which is distinct from SQL NULL.
  def active_count do
    Repo.aggregate(
      from(r in Run,
        where:
          r.status in ^@active or r.workspace_cleanup_pending or r.source_writer_pending or
            not is_nil(r.source_writer_token) or
            fragment("json_type(?) != 'null'", r.source_writer_origin)
      ),
      :count
    )
  end

  def cleanup_runs do
    Repo.all(from r in Run, where: r.workspace_cleanup_pending, order_by: [asc: r.inserted_at])
  end

  def writer_runs do
    Repo.all(
      from r in Run,
        where:
          r.source_writer_pending or not is_nil(r.source_writer_token) or
            fragment("json_type(?) != 'null'", r.source_writer_origin),
        order_by: [asc: r.inserted_at]
    )
  end

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Run{} = run <- Repo.get(Run, id) do
      {:ok, run}
    else
      _missing -> {:error, :not_found}
    end
  end

  def by_session(id), do: Repo.get_by(Run, session_id: id)

  def create(attrs) do
    id = Ecto.UUID.generate()
    attrs = Map.merge(attrs, %{session_id: "docs-#{id}"})

    case Repo.transaction(fn ->
           run = %Run{id: id} |> Run.changeset(attrs) |> Repo.insert!()
           append!(run, "run_queued", %{mode: run.mode}, %{}, nil)
         end) do
      {:ok, run} ->
        notify(run.id)
        {:ok, run}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def append(id, kind, payload, updates \\ %{}, native_seq \\ nil) do
    {:ok, {run, changed?}} =
      Repo.transaction(fn ->
        run = Repo.get!(Run, id)

        if is_integer(native_seq) and native_seq <= run.last_native_seq do
          {run, false}
        else
          {append!(run, kind, payload, updates, native_seq), true}
        end
      end)

    if changed?, do: notify(id)
    run
  end

  def update_writer(%Run{} = expected_run, kind, payload, updates) do
    case Repo.transaction(fn -> update_writer!(expected_run, kind, payload, updates) end) do
      {:ok, run} ->
        notify(run.id)
        {:ok, run}

      {:error, :writer_claim_mismatch} = error ->
        error
    end
  end

  def refresh(run, updates) do
    if Enum.any?(updates, fn {key, value} -> Map.fetch!(run, key) != value end) do
      updated = run |> Run.changeset(updates) |> Repo.update!()
      notify(run.id)
      updated
    else
      run
    end
  end

  defp update_writer!(expected_run, kind, payload, updates) do
    run = Repo.get(Run, expected_run.id)

    if writer_claim_matches?(run, expected_run) do
      append!(run, kind, payload, updates, nil)
    else
      Repo.rollback(:writer_claim_mismatch)
    end
  end

  defp writer_claim_matches?(
         %Run{source_writer_pending: true, source_writer_token: token} = run,
         expected_run
       )
       when not is_nil(token) and not is_nil(run.session_id) and not is_nil(run.workspace) do
    token == expected_run.source_writer_token and run.session_id == expected_run.session_id and
      run.workspace == expected_run.workspace and
      run.source_writer_origin == expected_run.source_writer_origin
  end

  defp writer_claim_matches?(_run, _expected_run), do: false

  defp append!(run, kind, payload, updates, native_seq) do
    seq = run.last_seq + 1

    %RunEvent{}
    |> RunEvent.changeset(%{
      run_id: run.id,
      seq: seq,
      native_seq: native_seq,
      kind: kind,
      payload: Snapshot.payload(payload)
    })
    |> Repo.insert!()

    updates = Map.put(updates, :last_seq, seq)

    updates =
      if is_integer(native_seq), do: Map.put(updates, :last_native_seq, native_seq), else: updates

    run |> Run.changeset(updates) |> Repo.update!()
  end

  defp notify(id),
    do: Phoenix.PubSub.broadcast(OhMyJidoDocs.PubSub, Editor.topic(id), {:docs_run_updated, id})
end
