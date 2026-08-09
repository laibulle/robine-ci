defmodule Robine.Repositories.UseCases.SyncGitHubChecks do
  @moduledoc "Idempotently projects durable pipeline and job state to GitHub check runs."
  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies

  @spec call(map(), ExecutionContext.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def call(
        %{pipeline_id: pipeline_id},
        %ExecutionContext{
          actor: %{role: :administrator},
          dependencies: %{repositories: %Dependencies{} = deps}
        } = context
      )
      when is_binary(pipeline_id) do
    with {:ok, snapshot} <- Pipelines.pipeline_snapshot(%{pipeline_id: pipeline_id}, context),
         {:ok, repository} <- deps.repository.get_by_id(snapshot.repository_id) do
      checks = [
        pipeline_check(snapshot, deps.public_url)
        | Enum.map(snapshot.jobs, &job_check(snapshot, &1, deps.public_url))
      ]

      Enum.reduce_while(checks, {:ok, 0}, fn check, {:ok, count} ->
        case sync_one(repository, check, deps) do
          :ok -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp sync_one(repository, check, deps) do
    existing =
      case deps.repository.get_check(
             repository.provider,
             repository.provider_instance,
             check.external_key
           ) do
        {:ok, value} -> value
        {:error, :not_found} -> nil
      end

    request = Map.put(check.request, :provider_check_id, existing && existing.provider_check_id)

    with {:ok, provider_check_id} <- deps.source_control.upsert_check(repository, request),
         :ok <-
           deps.repository.upsert_check(%{
             provider: repository.provider,
             provider_instance: repository.provider_instance,
             external_key: check.external_key,
             repository_id: repository.id,
             pipeline_id: check.pipeline_id,
             job_id: check.job_id,
             provider_check_id: provider_check_id,
             status: to_string(check.request.status),
             conclusion: optional_string(check.request[:conclusion])
           }),
         do: :ok
  end

  defp pipeline_check(snapshot, public_url) do
    %{
      external_key: "pipeline:#{snapshot.id}",
      pipeline_id: snapshot.id,
      job_id: nil,
      request:
        request(
          "Robine / #{snapshot.workflow_name}",
          snapshot.commit_sha,
          snapshot.status,
          "#{public_url}/pipelines/#{snapshot.id}",
          pipeline_summary(snapshot),
          "pipeline:#{snapshot.id}"
        )
    }
  end

  defp pipeline_summary(%{trigger: trigger, status: status})
       when trigger in [:workflow_dispatch, "workflow_dispatch"],
       do: "Pipeline is #{status}. Trigger: manual workflow dispatch."

  defp pipeline_summary(%{trigger: trigger, status: status, scheduled_for: scheduled_for})
       when trigger in [:schedule, "schedule"] and not is_nil(scheduled_for),
       do: "Pipeline is #{status}. Trigger: schedule for #{DateTime.to_iso8601(scheduled_for)}."

  defp pipeline_summary(%{status: status}), do: "Pipeline is #{status}."

  defp job_check(snapshot, job, public_url) do
    %{
      external_key: "job:#{job.id}",
      pipeline_id: snapshot.id,
      job_id: job.id,
      request:
        request(
          "Robine / #{job.job_key}",
          snapshot.commit_sha,
          job.status,
          "#{public_url}/pipelines/#{snapshot.id}/jobs/#{job.id}",
          job_summary(job),
          "job:#{job.id}"
        )
    }
  end

  defp job_summary(%{matrix_values: values, status: status}) when map_size(values) > 0 do
    matrix =
      values |> Enum.sort() |> Enum.map_join(", ", fn {axis, value} -> "#{axis}=#{value}" end)

    "Job is #{status}. Matrix: #{matrix}"
  end

  defp job_summary(job), do: "Job is #{job.status}"

  defp request(name, sha, local_status, details_url, summary, external_id) do
    {status, conclusion} = github_state(local_status)

    base = %{
      name: name,
      head_sha: sha,
      status: status,
      details_url: details_url,
      external_id: external_id,
      output: %{title: name, summary: summary}
    }

    if conclusion, do: Map.put(base, :conclusion, conclusion), else: base
  end

  defp github_state(status) when status in [:created, :queued, :blocked], do: {:queued, nil}

  defp github_state(status) when status in [:running, :cancelling, :preparing],
    do: {:in_progress, nil}

  defp github_state(:succeeded), do: {:completed, :success}
  defp github_state(:failed), do: {:completed, :failure}
  defp github_state(:cancelled), do: {:completed, :cancelled}
  defp github_state(:skipped), do: {:completed, :neutral}
  defp github_state(_status), do: {:queued, nil}
  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)
end
