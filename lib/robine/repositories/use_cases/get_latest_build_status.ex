defmodule Robine.Repositories.UseCases.GetLatestBuildStatus do
  @moduledoc "Returns the newest pipeline status for a trusted repository badge."
  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies

  @pipeline_limit 100

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(
        %{repository_id: repository_id},
        %ExecutionContext{
          actor: %{role: role},
          dependencies: %{repositories: %Dependencies{} = deps}
        } = context
      )
      when role in [:administrator, :maintainer, :viewer] and is_binary(repository_id) do
    with {:ok, %{trusted: true}} <- deps.repository.get_by_id(repository_id),
         {:ok, pipelines} <- Pipelines.list_pipelines(%{limit: @pipeline_limit}, context),
         pipeline when not is_nil(pipeline) <-
           Enum.find(pipelines, &(&1.repository_id == repository_id)) do
      {:ok, %{status: pipeline.status, pipeline_id: pipeline.id}}
    else
      {:ok, _untrusted} -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}
end
