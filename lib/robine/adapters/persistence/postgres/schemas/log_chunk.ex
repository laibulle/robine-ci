defmodule Robine.Adapters.Persistence.Postgres.Schemas.LogChunk do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}

  schema "log_chunks" do
    field :attempt_id, :binary_id
    field :sequence, :integer
    field :phase, :string
    field :step_position, :integer
    field :step_name, :string
    field :step_status, :string
    field :exit_code, :integer
    field :duration_ms, :integer
    field :content, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :attempt_id,
      :sequence,
      :phase,
      :step_position,
      :step_name,
      :step_status,
      :exit_code,
      :duration_ms,
      :content
    ])
    |> validate_required([
      :attempt_id,
      :sequence,
      :phase,
      :step_position,
      :step_name,
      :step_status,
      :duration_ms,
      :content
    ])
    |> unique_constraint([:attempt_id, :sequence])
  end
end
