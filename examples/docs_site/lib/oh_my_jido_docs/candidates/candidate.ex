defmodule OhMyJidoDocs.Candidates.Candidate do
  @moduledoc "An immutable reviewed source identity and its durable effect receipts."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "docs_candidates" do
    field :run_id, :binary_id
    field :digest, :string
    field :source_path, :string
    field :app_relative, :string
    field :source_root, :string
    field :base_root, :string
    field :base_revision, :string
    field :workspace_path, :string
    field :workspace_digest, :string
    field :manifest, :map, default: %{}
    field :base_manifest, :map, default: %{}
    field :changed_paths, {:array, :string}, default: []
    field :diff, :string
    field :status, :string, default: "prepared"
    field :check_status, :string, default: "pending"
    field :check_digest, :string
    field :check_output, :string, default: ""
    field :check_receipt, :map, default: %{}
    field :preview_status, :string, default: "stopped"
    field :preview_url, :string
    field :preview_output, :string, default: ""
    field :preview_receipt, :map, default: %{}
    field :approval_digest, :string
    field :approved_at, :utc_datetime_usec
    field :published_base_digest, :string
    field :publication_digest, :string
    field :publication_receipt, :map, default: %{}
    field :adoption_status, :string, default: "pending"
    field :adoption_receipt, :map, default: %{}
    field :deployment_status, :string, default: "pending"
    field :deployment_output, :string, default: ""
    field :deployment_receipt, :map, default: %{}
    field :lock_version, :integer, default: 1
    timestamps(type: :utc_datetime_usec)
  end

  @immutable_fields [
    :run_id,
    :digest,
    :source_path,
    :app_relative,
    :source_root,
    :base_root,
    :base_revision,
    :workspace_path,
    :workspace_digest,
    :manifest,
    :base_manifest,
    :changed_paths,
    :diff,
    :published_base_digest
  ]

  @effect_fields [
    :status,
    :check_status,
    :check_digest,
    :check_output,
    :check_receipt,
    :preview_status,
    :preview_url,
    :preview_output,
    :preview_receipt,
    :approval_digest,
    :approved_at,
    :publication_digest,
    :publication_receipt,
    :adoption_status,
    :adoption_receipt,
    :deployment_status,
    :deployment_output,
    :deployment_receipt
  ]

  def create_changeset(candidate, attrs) do
    candidate
    |> cast(attrs, @immutable_fields)
    |> validate_required([
      :run_id,
      :digest,
      :source_path,
      :app_relative,
      :source_root,
      :base_root,
      :base_revision,
      :workspace_path,
      :workspace_digest,
      :manifest,
      :base_manifest,
      :changed_paths,
      :diff,
      :published_base_digest
    ])
    |> validate_format(:digest, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:run_id)
  end

  def effect_changeset(candidate, attrs) do
    candidate
    |> cast(attrs, @effect_fields)
    |> optimistic_lock(:lock_version)
  end
end
