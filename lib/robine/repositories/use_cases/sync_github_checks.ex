defmodule Robine.Repositories.UseCases.SyncGitHubChecks do
  @moduledoc "Idempotently projects durable pipeline and job state to GitHub check runs."
  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.CoverageReport

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
          pipeline_summary(snapshot, coverage_by_job),
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

  defp pipeline_summary(snapshot, coverage_by_job) do
    coverage =
      snapshot.jobs
      |> Enum.map(fn job -> {job.job_key, Map.get(coverage_by_job, job.id)} end)
      |> Enum.reject(fn {_job_key, report} -> is_nil(report) end)

    append_pipeline_coverage(pipeline_status_summary(snapshot), coverage)
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
          job_summary(job, coverage),
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

  defp job_summary(job, coverage) do
    append_coverage(job_status_summary(job), coverage)
  end

  defp append_pipeline_coverage(summary, []), do: summary

  defp append_pipeline_coverage(summary, coverage) do
    rows =
      Enum.map_join(coverage, "\n", fn {job_key, report} ->
        "- `#{job_key}`: **#{report.total}%** (threshold #{report.threshold}%)"
      end)

    summary <> "\n\n### Coverage\n" <> rows
  end

  defp append_coverage(summary, nil), do: summary

  defp append_coverage(summary, report) do
    outcome = if report.total_value >= report.threshold_value, do: "passed", else: "failed"

    summary <>
      "\n\nCoverage: **#{report.total}%** · threshold #{report.threshold}% · #{outcome}. " <>
      "Report artifact: `#{report.report}`."
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
end
