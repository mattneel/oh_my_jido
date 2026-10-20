defmodule OhMyJidoDocs.Repo.Migrations.CreateEditorRuns do
  use Ecto.Migration

  def change do
    create table(:editor_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :task, :text, null: false
      add :mode, :string, null: false, default: "docs"
      add :session_id, :string, null: false
      add :native_run_id, :string
      add :workspace, :text
      add :workspace_cleanup_pending, :boolean, null: false, default: false
      add :source_writer_pending, :boolean, null: false, default: false
      add :source_writer_token, :string
      add :base_revision, :string
      add :status, :string, null: false, default: "queued"
      add :summary, :text
      add :last_seq, :integer, null: false, default: 0
      add :last_native_seq, :integer, null: false, default: 0
      add :pending_questions, :map, null: false, default: %{}
      add :session_snapshot, :map
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:editor_runs, [:session_id])
    create index(:editor_runs, [:status, :updated_at])
    create index(:editor_runs, [:workspace, :source_writer_pending])

    create table(:editor_run_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:editor_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :seq, :integer, null: false
      add :native_seq, :integer
      add :kind, :string, null: false
      add :payload, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:editor_run_events, [:run_id, :seq])
    create unique_index(:editor_run_events, [:run_id, :native_seq])
  end
end
