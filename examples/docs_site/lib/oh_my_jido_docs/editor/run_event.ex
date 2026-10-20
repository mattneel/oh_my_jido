defmodule OhMyJidoDocs.Editor.RunEvent do
  @moduledoc "An ordered, bounded, sanitized native or host lifecycle observation."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "editor_run_events" do
    belongs_to :run, OhMyJidoDocs.Editor.Run
    field :seq, :integer
    field :native_seq, :integer
    field :kind, :string
    field :payload, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:run_id, :seq, :native_seq, :kind, :payload])
    |> validate_required([:run_id, :seq, :kind, :payload])
    |> foreign_key_constraint(:run_id)
    |> unique_constraint([:run_id, :seq])
    |> unique_constraint([:run_id, :native_seq])
  end
end
