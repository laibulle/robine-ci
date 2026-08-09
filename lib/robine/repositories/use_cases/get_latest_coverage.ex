defmodule Robine.Repositories.UseCases.GetLatestCoverage do
  @moduledoc "Returns the newest retained coverage measurement for a trusted repository."
  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.CoverageReport

  @pipeline_limit 100
  @log_page_limit 50

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
         {:ok, pipelines} <- Pipelines.list_pipelines(%{limit: @pipeline_limit}, context) do
      pipelines
      |> Enum.filter(&(&1.repository_id == repository_id and terminal?(&1.status)))
      |> Enum.reduce_while({:error, :not_found}, fn pipeline, _missing ->
        case coverage_for_pipeline(pipeline.id, context) do
          {:ok, coverage} -> {:halt, {:ok, Map.put(coverage, :pipeline_id, pipeline.id)}}
          :error -> {:cont, {:error, :not_found}}
        end
      end)
    else
      {:ok, _untrusted} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp coverage_for_pipeline(pipeline_id, context) do
    with {:ok, snapshot} <- Pipelines.pipeline_snapshot(%{pipeline_id: pipeline_id}, context) do
      Enum.reduce_while(snapshot.jobs, :error, fn job, _missing ->
        case read_pages(job.id, 0, 0, nil, context) do
          nil -> {:cont, :error}
          report -> {:halt, {:ok, Map.put(report, :job_id, job.id)}}
        end
      end)
    else
      _ -> :error
    end
  end

  defp read_pages(_job_id, _cursor, @log_page_limit, report, _context), do: report

  defp read_pages(job_id, cursor, page_count, report, context) do
    case Pipelines.list_job_logs(%{job_id: job_id, after: cursor, limit: 200}, context) do
      {:ok, page} ->
        next_report =
          Enum.reduce(page.chunks, report, fn chunk, current ->
            case CoverageReport.parse(chunk.content) do
              {:ok, parsed} -> parsed
              :error -> current
            end
          end)

        if page.has_more and page.next_cursor > cursor do
          read_pages(job_id, page.next_cursor, page_count + 1, next_report, context)
        else
          next_report
        end

      {:error, _reason} ->
        report
    end
  end

  defp terminal?(status), do: status in [:succeeded, :failed, :cancelled]
end
