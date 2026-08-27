defmodule Robine.Deployments.UseCases.RequestDeployment do
  @moduledoc "Snapshots and requests promotion of one exact successful tag artifact."

  alias Robine.Deployments.Dependencies
  alias Robine.Deployments.Domain.{ArtifactSnapshot, Deployment}
  alias Robine.ExecutionContext

  def call(input, %ExecutionContext{
        actor: %{id: actor_id},
        capabilities: capabilities,
        correlation_id: correlation_id,
        dependencies: %{deployments: %Dependencies{} = deps}
      }) do
    if MapSet.member?(capabilities, :ci_run) or MapSet.member?(capabilities, :ci_manage) do
      now = DateTime.truncate(deps.clock.now(), :microsecond)

      with {:ok, environment} <- deps.repository.get_environment(Map.get(input, :environment_id)),
           {:ok, resolved} <-
             deps.artifact_resolver.resolve(environment.repository_id, Map.get(input, :artifact_id)),
           {:ok, artifact} <- ArtifactSnapshot.new(resolved),
           {:ok, deployment} <-
             Deployment.new(
               %{
                 id: deps.id_generator.generate(),
                 requester_id: actor_id,
                 kind: Map.get(input, :kind, :application)
               },
               environment,
               artifact,
               now
             ),
           :ok <-
             deps.repository.insert_deployment(deployment, %{
               actor_id: actor_id,
               correlation_id: correlation_id
             }) do
        {:ok, deployment_view(deployment)}
      end
    else
      {:error, :forbidden}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp deployment_view(deployment) do
    deployment |> Map.from_struct() |> Map.update!(:artifact, &Map.from_struct/1)
  end
end
