defmodule Robine.Adapters.Persistence.Postgres.Schemas.AutoscalingPolicy do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "autoscaling_policies" do
    field :name, :string
    field :enabled, :boolean, default: false
    field :provider, :string
    field :runner_template, :map, default: %{}
    field :labels, {:array, :string}, default: []
    field :min_runners, :integer
    field :max_runners, :integer
    field :concurrency, :integer
    field :idle_timeout_seconds, :integer
    field :scale_up_cooldown_seconds, :integer
    field :scale_down_cooldown_seconds, :integer
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :name,
      :enabled,
      :provider,
      :runner_template,
      :labels,
      :min_runners,
      :max_runners,
      :concurrency,
      :idle_timeout_seconds,
      :scale_up_cooldown_seconds,
      :scale_down_cooldown_seconds,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([
      :id,
      :name,
      :enabled,
      :provider,
      :runner_template,
      :labels,
      :min_runners,
      :max_runners,
      :concurrency,
      :idle_timeout_seconds,
      :scale_up_cooldown_seconds,
      :scale_down_cooldown_seconds
    ])
    |> unique_constraint(:name)
  end
end
