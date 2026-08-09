defmodule Robine.Repositories.UseCases.ProcessGitHubDelivery do
  @moduledoc "Normalizes one delivery, loads exact-SHA workflows, and creates matching pipelines."
  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies
  alias Robine.Workflows

  @pull_request_actions ~w(opened reopened synchronize ready_for_review)

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
         {:ok, event} <- normalize(delivery.event, delivery.payload),
         {:ok, repository} <- deps.repository.get_by_provider_id(event.repository_id),
         true <- repository.trusted,
         {:ok, files} <- deps.github.workflow_files(repository, event.sha),
         {:ok, pipeline_ids} <- create_matching(files, event, repository, context),
         :ok <- deps.repository.finish_delivery(id, :processed, deps.clock.now(), nil) do
      {:ok, %{pipeline_ids: pipeline_ids, commit_sha: event.sha}}
    else
      {:ignore, reason} ->
        :ok = deps.repository.finish_delivery(id, :ignored, deps.clock.now(), to_string(reason))
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

  defp normalize("push", %{
         "repository" => %{"id" => repository_id},
         "after" => sha,
         "ref" => "refs/heads/" <> branch
       })
       when is_integer(repository_id) and is_binary(sha),
       do: {:ok, %{type: :push, repository_id: repository_id, sha: sha, branch: branch}}

  defp normalize("pull_request", %{"action" => action}) when action not in @pull_request_actions,
    do: {:ignore, :pull_request_action}

  defp normalize("pull_request", %{"pull_request" => %{"draft" => true}}),
    do: {:ignore, :draft_pull_request}

  defp normalize("pull_request", payload) do
    with %{"repository" => %{"id" => repository_id}, "pull_request" => pull_request} <- payload,
         %{
           "head" => %{"sha" => sha, "repo" => %{"full_name" => head_name}},
           "base" => %{"ref" => branch, "repo" => %{"full_name" => base_name}}
         } <- pull_request do
      if head_name == base_name,
        do: {:ok, %{type: :pull_request, repository_id: repository_id, sha: sha, branch: branch}},
        else: {:ignore, :fork_pull_request}
    else
      _ -> {:error, {:invalid_webhook, :pull_request_payload}}
    end
  end

  defp normalize(event, _payload), do: {:ignore, {:unsupported_event, event}}

  defp create_matching(files, event, repository, context) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, pipeline_ids} ->
      case Workflows.validate(%{source: file.content, path: file.path}, context) do
        {:ok, validated} ->
          if trigger_matches?(validated.workflow.triggers, event) do
            input = %{
              repository_id: repository.id,
              workflow_name: validated.workflow.name,
              commit_sha: event.sha,
              jobs: validated.workflow.jobs,
              workflow_revision: %{path: file.path, source: file.content}
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

  defp trigger_matches?(triggers, %{type: type, branch: branch}) do
    key = if type == :push, do: "push", else: "pull_request"

    case Map.get(triggers, key) do
      nil -> false
      config when config == %{} -> true
      %{"branches" => branches} when is_list(branches) -> branch in branches
      _configuration -> true
    end
  end
end
