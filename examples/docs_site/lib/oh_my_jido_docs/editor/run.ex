defmodule OhMyJidoDocs.Editor.Run do
  @moduledoc "A durable editorial session and its latest native run identity."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(queued running waiting cancelling suspending completed failed cancelled suspended interrupted ready timed_out)

  schema "editor_runs" do
    field :task, :string
    field :mode, :string, default: "docs"
    field :session_id, :string
    field :native_run_id, :string
    field :workspace, :string
    field :workspace_cleanup_pending, :boolean, default: false
    field :source_writer_pending, :boolean, default: false
    field :source_writer_token, :string
    field :source_writer_origin, :map
    field :base_revision, :string
    field :status, :string, default: "queued"
    field :summary, :string
    field :last_seq, :integer, default: 0
    field :last_native_seq, :integer, default: 0
    field :pending_questions, :map, default: %{}
    field :session_snapshot, :map

    has_many :events, OhMyJidoDocs.Editor.RunEvent
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :task,
      :mode,
      :session_id,
      :native_run_id,
      :workspace,
      :workspace_cleanup_pending,
      :source_writer_pending,
      :source_writer_token,
      :source_writer_origin,
      :base_revision,
      :status,
      :summary,
      :last_seq,
      :last_native_seq,
      :pending_questions,
      :session_snapshot
    ])
    |> validate_required([:task, :mode, :session_id, :status])
    |> validate_length(:task, min: 1, max: 16_384)
    |> validate_inclusion(:mode, ["docs", "coding"])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:session_id)
  end
end
