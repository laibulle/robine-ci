defmodule Robine.Adapters.Persistence.Postgres.Schemas.Job do
  @moduledoc false
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "pipeline_jobs" do
    field :pipeline_id, :binary_id
    field :job_key, :string
    field :status, Ecto.Enum, values: Robine.Pipelines.Domain.Job.statuses()
    field :needs, {:array, :string}, default: []
    field :position, :integer
    field :execution_spec, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [:id, :pipeline_id, :job_key, :status, :needs, :position, :execution_spec])
    |> validate_required([:id, :pipeline_id, :job_key, :status, :needs, :position])
    |> unique_constraint([:pipeline_id, :job_key])
  end
end
