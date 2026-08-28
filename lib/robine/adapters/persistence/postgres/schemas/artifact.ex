defmodule Robine.Adapters.Persistence.Postgres.Schemas.Artifact do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "artifacts" do
    field :repository_id, :binary_id
    field :attempt_id, :binary_id
    field :source, Ecto.Enum, values: [:ci, :manual], default: :ci
    field :uploaded_by_id, :binary_id
    field :name, :string
    field :content_type, :string, default: "application/gzip"
    field :blob_id, :string
    field :digest, :string
    field :size, :integer
    field :created_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :repository_id,
      :attempt_id,
      :source,
      :uploaded_by_id,
      :name,
      :content_type,
      :blob_id,
      :digest,
      :size,
      :created_at,
      :expires_at
    ])
    |> validate_required([
      :id,
      :repository_id,
      :source,
      :name,
      :content_type,
      :blob_id,
      :digest,
      :size,
      :created_at,
      :expires_at
    ])
    |> validate_provenance()
    |> unique_constraint([:attempt_id, :name])
    |> check_constraint(:source, name: :artifacts_valid_provenance)
  end

  defp validate_provenance(changeset) do
    case {get_field(changeset, :source), get_field(changeset, :attempt_id),
          get_field(changeset, :uploaded_by_id)} do
      {:ci, attempt_id, nil} when is_binary(attempt_id) -> changeset
      {:manual, nil, uploader_id} when is_binary(uploader_id) -> changeset
      _invalid -> add_error(changeset, :source, "has invalid provenance")
    end
  end
end
