defmodule Robine.Adapters.Persistence.Postgres.Schemas.GitHubCheck do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "github_checks" do
    field :provider, Ecto.Enum, values: [:github, :gitlab, :forgejo]
    field :provider_instance, :string
    field :external_key, :string
    field :repository_id, :binary_id
    field :pipeline_id, :binary_id
    field :job_id, :binary_id
    field :provider_check_id, :integer
    field :status, :string
    field :conclusion, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :external_key,
      :provider,
      :provider_instance,
      :repository_id,
      :pipeline_id,
      :job_id,
      :provider_check_id,
      :status,
      :conclusion
    ])
    |> validate_required([
      :external_key,
      :provider,
      :provider_instance,
      :repository_id,
      :pipeline_id,
      :provider_check_id,
      :status
    ])
    |> unique_constraint([:provider, :provider_instance, :external_key],
      name: :source_control_statuses_provider_external_key_index
    )
  end
end
