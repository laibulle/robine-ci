defmodule Robine.Adapters.Persistence.Postgres.Schemas.ApiToken do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "api_tokens" do
    field :user_id, :binary_id
    field :repository_id, :binary_id
    field :name, :string
    field :token_prefix, :string
    field :token_digest, :binary
    field :permissions, {:array, :string}
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :user_id,
      :repository_id,
      :name,
      :token_prefix,
      :token_digest,
      :permissions,
      :expires_at,
      :last_used_at,
      :revoked_at,
      :inserted_at
    ])
    |> validate_required([
      :id,
      :user_id,
      :repository_id,
      :name,
      :token_prefix,
      :token_digest,
      :permissions,
      :expires_at,
      :inserted_at
    ])
    |> validate_length(:name, min: 1, max: 64)
    |> validate_permissions()
    |> unique_constraint(:token_digest, name: :api_tokens_tenant_id_token_digest_index)
    |> check_constraint(:permissions, name: :api_tokens_artifact_upload_permission)
    |> check_constraint(:name, name: :api_tokens_name_length)
  end

  defp validate_permissions(changeset) do
    case get_field(changeset, :permissions) do
      ["artifacts:write"] -> changeset
      _invalid -> add_error(changeset, :permissions, "contains unsupported permissions")
    end
  end
end
