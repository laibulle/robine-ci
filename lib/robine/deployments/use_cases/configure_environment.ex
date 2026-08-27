defmodule Robine.Deployments.UseCases.ConfigureEnvironment do
  @moduledoc "Creates or replaces one administrator-owned native deployment environment."

  alias Robine.Deployments.Dependencies
  alias Robine.Deployments.Domain.Environment
  alias Robine.ExecutionContext

  def call(input, %ExecutionContext{
        actor: %{id: actor_id, role: :administrator},
        correlation_id: correlation_id,
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    now = DateTime.truncate(deps.clock.now(), :microsecond)
    repository_id = Map.get(input, :repository_id)
    name = Map.get(input, :name)

    existing =
      case deps.repository.get_environment_by_name(repository_id, name) do
        {:ok, environment} -> environment
        {:error, :not_found} -> nil
        {:error, reason} -> {:error, reason}
      end

    with false <- match?({:error, _reason}, existing),
         {:ok, environment} <-
           Environment.new(
             input
             |> Map.put(:id, (existing && existing.id) || deps.id_generator.generate())
             |> Map.put(:inserted_at, (existing && existing.inserted_at) || now)
             |> Map.put(:updated_at, now)
           ),
         :ok <-
           deps.repository.upsert_environment(environment, %{
             actor_id: actor_id,
             correlation_id: correlation_id
           }) do
      {:ok, view(environment)}
    else
      true -> existing
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp view(environment), do: Map.from_struct(environment)
end
