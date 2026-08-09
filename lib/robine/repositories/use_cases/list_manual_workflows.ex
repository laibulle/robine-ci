defmodule Robine.Repositories.UseCases.ListManualWorkflows do
  @moduledoc "Discovers manually enabled workflows from one exact branch head."

  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies
  alias Robine.Workflows

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(
        %{repository_id: repository_id} = input,
        %ExecutionContext{
          actor: %{role: role},
          dependencies: %{repositories: %Dependencies{} = deps}
        } = context
      )
      when role in [:administrator, :maintainer, :viewer] and is_binary(repository_id) do
    started = System.monotonic_time()

    result =
      with {:ok, repository} <- deps.repository.get_by_id(repository_id),
           true <- repository.trusted,
           {:ok, head} <- resolve_head(deps, repository, Map.get(input, :branch)),
           {:ok, head} <- valid_head(head),
           {:ok, files} <- deps.source_control.workflow_files(repository, head.sha),
           {:ok, workflows} <- manual_workflows(files, context) do
        {:ok, %{branch: head.branch, commit_sha: head.sha, workflows: workflows}}
      else
        false -> {:error, :untrusted_repository}
        error -> error
      end

    emit(:discovery, result, started)
    result
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp resolve_head(deps, repository, branch) when branch in [nil, ""],
    do: deps.source_control.default_branch_head(repository)

  defp resolve_head(deps, repository, branch) when is_binary(branch),
    do: deps.source_control.branch_head(repository, branch)

  defp resolve_head(_deps, _repository, _branch), do: {:error, :invalid_branch}

  defp manual_workflows(files, context) do
    sources = Map.new(files, &{&1.path, &1.content})

    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, workflows} ->
      case Workflows.resolve(%{entry_path: file.path, sources: sources}, context) do
        {:ok, validated} ->
          case get_in(validated.workflow.triggers, ["workflow_dispatch", "inputs"]) do
            inputs when is_map(inputs) ->
              workflow = %{
                path: file.path,
                name: validated.workflow.name,
                inputs: inputs
              }

              {:cont, {:ok, workflows ++ [workflow]}}

            _missing ->
              {:cont, {:ok, workflows}}
          end

        {:error, diagnostics} ->
          {:halt, {:error, {:invalid_workflow, file.path, diagnostics}}}
      end
    end)
  end

  defp emit(operation, result, started) do
    workflow_count =
      case result do
        {:ok, %{workflows: workflows}} -> length(workflows)
        {:error, _reason} -> 0
      end

    :telemetry.execute(
      [:robine, :workflow, :manual],
      %{duration: System.monotonic_time() - started, workflow_count: workflow_count},
      %{operation: operation, outcome: if(match?({:ok, _}, result), do: :ok, else: :error)}
    )
  end

  defp valid_head(%{branch: branch, sha: sha} = head)
       when is_binary(branch) and branch != "" and is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: {:ok, head},
      else: {:error, :invalid_default_branch_head}
  end

  defp valid_head(_head), do: {:error, :invalid_default_branch_head}
end
