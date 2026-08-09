defmodule Robine.Repositories.UseCases.ProcessGitHubDelivery do
  @moduledoc "Normalizes one delivery, loads exact-SHA workflows, and creates matching pipelines."
  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.SourceControlEvent
  alias Robine.Workflows

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(
        %{delivery_id: id},
        %ExecutionContext{
          actor: %{role: :administrator},
          dependencies: %{repositories: %Dependencies{} = deps}
        } = context
      )
      when is_binary(id) do
    with {:ok, delivery} <- deps.repository.get_delivery(id),
         {:ok, event} <- SourceControlEvent.normalize(delivery),
         {:ok, repository} <-
           deps.repository.get_by_provider(
             delivery.provider,
             delivery.provider_instance,
             event.repository_id
           ),
         true <- repository.trusted,
         {:ok, files} <- deps.source_control.workflow_files(repository, event.sha),
         {:ok, pipeline_ids} <- create_matching(files, event, repository, id, context),
         :ok <- deps.repository.finish_delivery(id, :processed, deps.clock.now(), nil) do
      {:ok, %{pipeline_ids: pipeline_ids, commit_sha: event.sha, provider: delivery.provider}}
    else
      {:ignore, reason} ->
        :ok = deps.repository.finish_delivery(id, :ignored, deps.clock.now(), inspect(reason))
        {:ok, %{ignored: reason}}

      false ->
        :ok =
          deps.repository.finish_delivery(id, :ignored, deps.clock.now(), "untrusted_repository")

        {:ok, %{ignored: :untrusted_repository}}

      {:error, reason} = error ->
        _ = deps.repository.finish_delivery(id, :failed, deps.clock.now(), inspect(reason))
        error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp create_matching(files, event, repository, delivery_id, context) do
    sources = source_map(files)

    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, pipeline_ids} ->
      case Workflows.resolve(%{entry_path: file.path, sources: sources}, context) do
        {:ok, validated} ->
          if trigger_matches?(validated.workflow.triggers, event) do
            input = %{
              repository_id: repository.id,
              workflow_name: validated.workflow.name,
              commit_sha: event.sha,
              trigger: event.type,
              actor: event.actor,
              inputs: event_inputs(event),
              idempotency_key: "#{repository.provider}:#{delivery_id}:#{file.path}",
              jobs: validated.workflow.jobs,
              workflow_revision: revision(file, validated)
            }

            case Pipelines.create_pipeline(input, context) do
              {:ok, pipeline} -> {:cont, {:ok, pipeline_ids ++ [pipeline.id]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:cont, {:ok, pipeline_ids}}
          end

        {:error, diagnostics} ->
          {:halt, {:error, {:invalid_workflow, file.path, diagnostics}}}
      end
    end)
  end

  defp source_map(files), do: Map.new(files, &{&1.path, &1.content})

  defp event_inputs(%{type: :tag, branch: tag}), do: %{"tag" => tag}
  defp event_inputs(_event), do: %{}

  defp revision(file, validated) do
    %{
      path: file.path,
      source: file.content,
      sources: Map.delete(validated.sources, file.path)
    }
  end

  defp trigger_matches?(triggers, %{type: type, branch: branch}) do
    key = if type in [:push, :tag], do: "push", else: "pull_request"

    case Map.get(triggers, key) do
      nil -> false
      config when config == %{} -> true
      %{"tags" => tags} when type == :tag and is_list(tags) -> matches_any?(branch, tags)
      %{"tags" => _tags} when type != :tag -> false
      %{"branches" => _branches} when type == :tag -> false
      %{"branches" => branches} when is_list(branches) -> matches_any?(branch, branches)
      _configuration -> true
    end
  end

  defp matches_any?(value, patterns) do
    Enum.any?(patterns, fn pattern ->
      pattern = to_string(pattern)
      expression = pattern |> Regex.escape() |> String.replace("\\*", ".*")
      Regex.match?(Regex.compile!("\\A#{expression}\\z"), value)
    end)
  end
end
