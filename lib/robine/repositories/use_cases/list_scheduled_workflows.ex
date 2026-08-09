defmodule Robine.Repositories.UseCases.ListScheduledWorkflows do
  @moduledoc "Discovers scheduled workflows from the exact default-branch head."

  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies
  alias Robine.Workflows

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(
        %{repository_id: repository_id},
        %ExecutionContext{
          actor: %{role: role},
          dependencies: %{repositories: %Dependencies{} = deps}
        } = context
      )
      when role in [:administrator, :maintainer, :viewer] and is_binary(repository_id) do
    with {:ok, repository} <- deps.repository.get_by_id(repository_id),
         true <- repository.trusted,
         {:ok, head} <- deps.source_control.default_branch_head(repository),
         {:ok, head} <- valid_head(head),
         {:ok, files} <- deps.source_control.workflow_files(repository, head.sha),
         {:ok, workflows} <- scheduled_workflows(files, context) do
      {:ok, %{branch: head.branch, commit_sha: head.sha, workflows: workflows}}
    else
      false -> {:error, :untrusted_repository}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp scheduled_workflows(files, context) do
    sources = Map.new(files, &{&1.path, &1.content})

    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, workflows} ->
      case Workflows.resolve(%{entry_path: file.path, sources: sources}, context) do
        {:ok, validated} ->
          schedules = Map.get(validated.workflow.triggers, "schedule", [])

          if schedules == [] do
            {:cont, {:ok, workflows}}
          else
            workflow = %{
              path: file.path,
              name: validated.workflow.name,
              schedules: Enum.map(schedules, & &1.cron)
            }

            {:cont, {:ok, workflows ++ [workflow]}}
          end

        {:error, diagnostics} ->
          {:halt, {:error, {:invalid_workflow, file.path, diagnostics}}}
      end
    end)
  end

  defp valid_head(%{branch: branch, sha: sha} = head)
       when is_binary(branch) and branch != "" and is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: {:ok, head},
      else: {:error, :invalid_default_branch_head}
  end

  defp valid_head(_head), do: {:error, :invalid_default_branch_head}
end
