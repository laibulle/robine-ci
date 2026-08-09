defmodule Robine.Storage.UseCases.DownloadDependencyArtifact do
  @moduledoc "Downloads a retained artifact from one declared successful dependency job."

  alias Robine.ExecutionContext
  alias Robine.Storage.Contracts.Download
  alias Robine.Storage.Dependencies

  def call(input, %ExecutionContext{
        actor: %{role: role},
        dependencies: %{storage: %Dependencies{} = deps}
      })
      when role in [:administrator, :maintainer] do
    with {:ok, values} <- validate(input),
         true <- values.from_job in values.needs,
         {:ok, artifact} <-
           deps.repository.get_dependency_artifact(
             values.pipeline_id,
             values.from_job,
             values.name
           ),
         :ok <- not_expired(artifact.expires_at, deps.clock.now()),
         {:ok, content} <- deps.blob_store.get(artifact.blob_id, artifact.digest) do
      {:ok,
       %Download{
         name: artifact.name,
         digest: artifact.digest,
         size: artifact.size,
         content: content
       }}
    else
      false -> {:error, :undeclared_dependency}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp validate(input) do
    values = %{
      pipeline_id: Map.get(input, :pipeline_id),
      from_job: Map.get(input, :from_job),
      name: Map.get(input, :name),
      needs: Map.get(input, :needs, [])
    }

    if Enum.all?([values.pipeline_id, values.from_job, values.name], &is_binary/1) and
         is_list(values.needs) and Enum.all?(values.needs, &is_binary/1),
       do: {:ok, values},
       else: {:error, :invalid_dependency_artifact_request}
  end

  defp not_expired(expires_at, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: :ok,
      else: {:error, :artifact_expired}
  end
end
