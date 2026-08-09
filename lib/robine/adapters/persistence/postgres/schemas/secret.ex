defmodule Robine.Adapters.Persistence.Postgres.Schemas.Secret do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "secrets" do
    field :name, :string
    field :scope, Ecto.Enum, values: [:repository, :instance]
    field :repository_id, :binary_id
    field :allowed_repository_ids, {:array, :binary_id}, default: []
    field :ciphertext, :binary, redact: true
    field :nonce, :binary, redact: true
    field :tag, :binary, redact: true
    field :key_version, :integer
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :name,
      :scope,
      :repository_id,
      :allowed_repository_ids,
      :ciphertext,
      :nonce,
      :tag,
      :key_version,
      :inserted_at
    ])
    |> validate_required([
      :id,
      :name,
      :scope,
      :ciphertext,
      :nonce,
      :tag,
      :key_version,
      :inserted_at
    ])
    |> unique_constraint([:scope, :repository_id, :name],
      name: :secrets_scope_repository_name_index
    )
  end
end
