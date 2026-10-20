defmodule OhMyJidoDocs.Repo.Migrations.CreateDocsCandidates do
  use Ecto.Migration

  def change do
    create table(:docs_candidates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :run_id, references(:editor_runs, type: :binary_id, on_delete: :delete_all), null: false
      add :digest, :text, null: false
      add :source_path, :text, null: false
      add :app_relative, :text, null: false
      add :source_root, :text, null: false
      add :base_root, :text, null: false
      add :base_revision, :text, null: false
      add :workspace_path, :text, null: false
      add :workspace_digest, :text, null: false
      add :manifest, :map, null: false
      add :base_manifest, :map, null: false
      add :changed_paths, {:array, :string}, null: false
      add :diff, :text, null: false
      add :status, :text, null: false, default: "prepared"
      add :check_status, :text, null: false, default: "pending"
      add :check_digest, :text
      add :check_output, :text, null: false, default: ""
      add :check_receipt, :map, null: false, default: %{}
      add :preview_status, :text, null: false, default: "stopped"
      add :preview_url, :text
      add :preview_output, :text, null: false, default: ""
      add :preview_receipt, :map, null: false, default: %{}
      add :approval_digest, :text
      add :approved_at, :utc_datetime_usec
      add :published_base_digest, :text, null: false
      add :publication_digest, :text
      add :publication_receipt, :map, null: false, default: %{}
      add :adoption_status, :text, null: false, default: "pending"
      add :adoption_receipt, :map, null: false, default: %{}
      add :deployment_status, :text, null: false, default: "pending"
      add :deployment_output, :text, null: false, default: ""
      add :deployment_receipt, :map, null: false, default: %{}
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime_usec)
    end

    create index(:docs_candidates, [:run_id, :inserted_at])
    create index(:docs_candidates, [:check_status])
  end
end
