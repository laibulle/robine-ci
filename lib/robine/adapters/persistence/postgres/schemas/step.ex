defmodule Robine.Adapters.Persistence.Postgres.Schemas.Step do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "attempt_steps" do
    field :attempt_id, :binary_id
    field :name, :string
    field :position, :integer
    field :status, Ecto.Enum, values: Robine.Pipelines.Domain.Step.statuses()
    field :exit_code, :integer
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:id, :attempt_id, :name, :position, :status, :exit_code])
    |> validate_required([:id, :attempt_id, :name, :position, :status])
    |> unique_constraint([:attempt_id, :position])
  end
end
