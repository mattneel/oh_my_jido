defmodule OhMyJidoDocs.Repo.Migrations.AddWriterOrigin do
  use Ecto.Migration

  def change do
    alter table(:editor_runs) do
      add :source_writer_origin, :map
    end
  end
end
