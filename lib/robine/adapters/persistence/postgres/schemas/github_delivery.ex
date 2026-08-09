defmodule Robine.Adapters.Persistence.Postgres.Schemas.GitHubDelivery do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :string, autogenerate: false}

  schema "github_deliveries" do
    field :provider, Ecto.Enum, values: [:github, :gitlab, :forgejo]
    field :provider_instance, :string
    field :provider_delivery_id, :string
    field :event, :string
    field :payload, :map
    field :status, Ecto.Enum, values: [:pending, :processed, :ignored, :failed]
    field :received_at, :utc_datetime_usec
    field :processed_at, :utc_datetime_usec
    field :failure, :string
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :provider,
      :provider_instance,
      :provider_delivery_id,
      :event,
      :payload,
      :status,
      :received_at,
      :processed_at,
      :failure
    ])
    |> validate_required([
      :id,
      :provider,
      :provider_instance,
      :provider_delivery_id,
      :event,
      :payload,
      :status,
      :received_at
    ])
    |> unique_constraint(:id)
    |> unique_constraint([:provider, :provider_instance, :provider_delivery_id],
      name: :source_control_deliveries_provider_identity_index
    )
  end
end
