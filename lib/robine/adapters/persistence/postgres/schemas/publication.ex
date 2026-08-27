defmodule Robine.Adapters.Persistence.Postgres.Schemas.Publication do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "publications" do
    field :repository_id, :binary_id
    field :pipeline_id, :binary_id
    field :job_id, :binary_id
    field :attempt_id, :binary_id
    field :workflow_revision_id, :binary_id
    field :release, :string
    field :filename, :string
    field :content_type, :string
    field :digest, :string
    field :size, :integer
    field :status, Ecto.Enum, values: [:staged, :publishing, :published, :failed, :withdrawn]
    field :source_commit, :string
    field :source_tag, :string
    field :public_url, :string
    field :published_at, :utc_datetime_usec
    field :withdrawn_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(schema, attributes) do
    schema
    |> cast(attributes, [
      :id,
      :repository_id,
      :pipeline_id,
      :job_id,
      :attempt_id,
      :workflow_revision_id,
      :release,
      :filename,
      :content_type,
      :digest,
      :size,
      :status,
      :source_commit,
      :source_tag,
      :public_url,
      :published_at,
      :withdrawn_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([
      :id,
      :repository_id,
      :release,
      :filename,
      :content_type,
      :digest,
      :size,
      :status,
      :source_commit,
      :source_tag
    ])
    |> unique_constraint([:repository_id, :release, :filename],
      name: :publications_immutable_identity_index
    )
  end
end
