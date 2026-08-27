defmodule Robine.Publications.UseCases.ConfigureRepository do
  @moduledoc "Enables or disables explicit public release publication for one repository."
  alias Robine.ExecutionContext
  alias Robine.Publications.Dependencies
  alias Robine.Publications.Domain.RepositoryPolicy

  def call(input, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        correlation_id: correlation_id,
        dependencies: %{publications: %Dependencies{} = deps}
      }) do
    now = DateTime.truncate(deps.clock.now(), :microsecond)

    with {:ok, existing} <- deps.repository.get_policy(Map.get(input, :repository_id)),
         {:ok, policy} <-
           RepositoryPolicy.new(%{
             id: (existing && existing.id) || deps.id_generator.generate(),
             repository_id: Map.get(input, :repository_id),
             enabled: Map.get(input, :enabled),
             public_slug: Map.get(input, :public_slug),
             inserted_at: (existing && existing.inserted_at) || now,
             updated_at: now
           }),
         :ok <-
           deps.repository.upsert_policy(policy, %{
             actor_id: actor_id,
             correlation_id: correlation_id
           }) do
      {:ok, Map.from_struct(policy)}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
