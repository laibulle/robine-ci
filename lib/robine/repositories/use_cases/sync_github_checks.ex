defmodule Robine.Repositories.UseCases.SyncGitHubChecks do
  @moduledoc "Idempotently projects durable pipeline and job state to GitHub check runs."
  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.CoverageReport
  alias Robine.Storage

  @coverage_log_page_limit 50
  @terminal_job_statuses [:succeeded, :failed, :cancelled, :skipped]

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
      coverage_by_job =
        Map.new(snapshot.jobs, fn job -> {job.id, coverage_for_job(job, context)} end)

      checks = [
        pipeline_check(snapshot, coverage_by_job, deps.public_url)
        | Enum.map(
            snapshot.jobs,
            &job_check(snapshot, &1, Map.get(coverage_by_job, &1.id), deps.public_url)
          )
      ]

      with :ok <- maybe_publish_release(repository, snapshot, deps, context),
           {:ok, count} <-
             Enum.reduce_while(checks, {:ok, 0}, fn check, {:ok, count} ->
               case sync_one(repository, check, deps) do
                 :ok -> {:cont, {:ok, count + 1}}
                 {:error, reason} -> {:halt, {:error, reason}}
               end
             end) do
        {:ok, count}
      end
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

  defp pipeline_check(snapshot, coverage_by_job, public_url) do
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
          pipeline_summary(snapshot, coverage_by_job, public_url),
          "pipeline:#{snapshot.id}"
        )
    }
  end

  defp pipeline_status_summary(%{trigger: trigger, status: status})
       when trigger in [:workflow_dispatch, "workflow_dispatch"],
       do: "Pipeline is #{status}. Trigger: manual workflow dispatch."

  defp pipeline_status_summary(%{trigger: trigger, status: status, scheduled_for: scheduled_for})
       when trigger in [:schedule, "schedule"] and not is_nil(scheduled_for),
       do: "Pipeline is #{status}. Trigger: schedule for #{DateTime.to_iso8601(scheduled_for)}."

  defp pipeline_status_summary(%{status: status}), do: "Pipeline is #{status}."

  defp pipeline_summary(snapshot, coverage_by_job, public_url) do
    coverage =
      snapshot.jobs
      |> Enum.map(fn job -> {job, Map.get(coverage_by_job, job.id)} end)
      |> Enum.reject(fn {_job, report} -> is_nil(report) end)

    append_pipeline_coverage(pipeline_status_summary(snapshot), coverage, snapshot.id, public_url)
  end

  defp job_check(snapshot, job, coverage, public_url) do
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
          job_summary(snapshot, job, coverage, public_url),
          "job:#{job.id}"
        )
    }
  end

  defp job_status_summary(%{matrix_values: values, status: status}) when map_size(values) > 0 do
    matrix =
      values |> Enum.sort() |> Enum.map_join(", ", fn {axis, value} -> "#{axis}=#{value}" end)

    "Job is #{status}. Matrix: #{matrix}"
  end

  defp job_status_summary(job), do: "Job is #{job.status}"

  defp job_summary(snapshot, job, coverage, public_url) do
    append_coverage(job_status_summary(job), coverage, snapshot.id, job.id, public_url)
  end

  defp append_pipeline_coverage(summary, [], _pipeline_id, _public_url), do: summary

  defp append_pipeline_coverage(summary, coverage, pipeline_id, public_url) do
    rows =
      Enum.map_join(coverage, "\n", fn {job, report} ->
        url = artifact_url(public_url, pipeline_id, job.id, report.report)

        "- `#{job.job_key}`: **#{report.total}%** (threshold #{report.threshold}%) · " <>
          "[Download report](#{url})"
      end)

    summary <> "\n\n### Coverage\n" <> rows
  end

  defp append_coverage(summary, nil, _pipeline_id, _job_id, _public_url), do: summary

  defp append_coverage(summary, report, pipeline_id, job_id, public_url) do
    outcome = if report.total_value >= report.threshold_value, do: "passed", else: "failed"
    url = artifact_url(public_url, pipeline_id, job_id, report.report)

    summary <>
      "\n\nCoverage: **#{report.total}%** · threshold #{report.threshold}% · #{outcome}. " <>
      "[Download `#{report.report}`](#{url})."
  end

  defp artifact_url(public_url, pipeline_id, job_id, report) do
    encoded_report = URI.encode(report, &URI.char_unreserved?/1)
    "#{public_url}/pipelines/#{pipeline_id}/jobs/#{job_id}/artifacts/#{encoded_report}"
  end

  defp coverage_for_job(%{id: job_id, status: status}, context)
       when status in @terminal_job_statuses do
    read_coverage_pages(job_id, 0, 0, nil, context)
  end

  defp coverage_for_job(_job, _context), do: nil

  defp read_coverage_pages(_job_id, _cursor, @coverage_log_page_limit, coverage, _context),
    do: coverage

  defp read_coverage_pages(job_id, cursor, page_count, coverage, context) do
    case Pipelines.list_job_logs(%{job_id: job_id, after: cursor, limit: 200}, context) do
      {:ok, page} ->
        next_coverage =
          Enum.reduce(page.chunks, coverage, fn chunk, current ->
            case CoverageReport.parse(chunk.content) do
              {:ok, report} -> report
              :error -> current
            end
          end)

        if page.has_more and page.next_cursor > cursor do
          read_coverage_pages(
            job_id,
            page.next_cursor,
            page_count + 1,
            next_coverage,
            context
          )
        else
          next_coverage
        end

      {:error, _reason} ->
        coverage
    end
  end

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

  defp maybe_publish_release(
         repository,
         %{status: :succeeded, trigger: trigger, inputs: %{"tag" => tag}} = snapshot,
         deps,
         context
       )
       when trigger in [:tag, "tag"] do
    with true <- valid_release_tag?(tag),
         {:ok, artifact} <- release_artifact(snapshot.jobs, context),
         true <- function_exported?(deps.source_control, :publish_release, 2) do
      deps.source_control.publish_release(repository, %{
        tag: tag,
        sha: snapshot.commit_sha,
        asset_name: "robine-#{tag}-#{release_platform(artifact.name)}.tar.gz",
        content: artifact.content
      })
    else
      false -> {:error, :github_release_unsupported}
      {:error, reason} -> {:error, {:github_release, reason}}
    end
  end

  defp maybe_publish_release(_repository, _snapshot, _deps, _context), do: :ok

  defp release_artifact(jobs, context) do
    Enum.reduce_while(jobs, {:error, :not_found}, fn job, _missing ->
      case Storage.download_job_artifact_by_prefix(
             %{job_id: job.id, prefix: "github-release-"},
             context
           ) do
        {:ok, artifact} -> {:halt, {:ok, artifact}}
        {:error, :not_found} -> {:cont, {:error, :not_found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp release_platform("github-release-" <> platform), do: platform

  defp valid_release_tag?(tag),
    do: is_binary(tag) and Regex.match?(~r/\Av\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?\z/, tag)
end
