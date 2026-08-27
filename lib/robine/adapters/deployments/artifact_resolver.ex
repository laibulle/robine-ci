defmodule Robine.Adapters.Deployments.ArtifactResolver do
  @moduledoc false
  @behaviour Robine.Deployments.Ports.ArtifactResolver

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    Artifact,
    Attempt,
    GitHubRepository,
    Job,
    Pipeline
  }

  alias Robine.Repo

  @impl true
  def resolve(repository_id, artifact_id)
      when is_binary(repository_id) and is_binary(artifact_id) do
    now = DateTime.utc_now()

    query =
      from artifact in Artifact,
        join: attempt in Attempt,
        on: attempt.id == artifact.attempt_id,
        join: job in Job,
        on: job.id == attempt.job_id,
        join: pipeline in Pipeline,
        on: pipeline.id == job.pipeline_id,
        join: repository in GitHubRepository,
        on: repository.id == pipeline.repository_id,
        where:
          artifact.id == ^artifact_id and artifact.repository_id == ^repository_id and
            pipeline.repository_id == ^repository_id and pipeline.status == :succeeded and
            repository.trusted == true and artifact.expires_at > ^now,
        select: %{
          artifact_id: artifact.id,
          pipeline_id: pipeline.id,
          filename: artifact.name,
          digest: artifact.digest,
          size: artifact.size,
          tag: fragment("?->>'tag'", pipeline.inputs),
          commit_sha: pipeline.commit_sha
        }

    case Repo.one(query) do
      nil -> {:error, :artifact_not_deployable}
      %{tag: tag} = result when is_binary(tag) -> {:ok, result}
      _result -> {:error, :artifact_not_deployable}
    end
  end

  def resolve(_repository_id, _artifact_id), do: {:error, :artifact_not_deployable}
end
