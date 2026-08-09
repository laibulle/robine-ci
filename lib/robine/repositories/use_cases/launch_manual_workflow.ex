defmodule Robine.Repositories.UseCases.LaunchManualWorkflow do
  @moduledoc "Launches one revalidated manual workflow at an exact branch SHA."

  alias Robine.ExecutionContext
  alias Robine.Pipelines
  alias Robine.Repositories.Dependencies
  alias Robine.Workflows

  @spec call(map(), ExecutionContext.t()) :: {:ok, map()} | {:error, term()}
  def call(
        %{
          repository_id: repository_id,
          workflow_path: path,
          request_id: request_id,
          inputs: inputs
        } = input,
        %ExecutionContext{
          actor: %{id: actor_id, role: role},
          dependencies: %{repositories: %Dependencies{} = deps}
        } = context
      )
      when role in [:administrator, :maintainer] and is_binary(repository_id) and
             is_binary(path) and byte_size(path) in 1..512 and is_binary(request_id) and
             byte_size(request_id) in 1..128 and is_map(inputs) do
    started = System.monotonic_time()

    result =
      with {:ok, repository} <- deps.repository.get_by_id(repository_id),
           true <- repository.trusted,
           {:ok, head} <- resolve_head(deps, repository, Map.get(input, :branch)),
           {:ok, head} <- valid_head(head),
           {:ok, files} <- deps.source_control.workflow_files(repository, head.sha),
           {:ok, file} <- exact_file(files, path),
           {:ok, validated} <- resolve(file, files, context),
           {:ok, prepared} <-
             Workflows.prepare_manual_run(%{validated_workflow: validated, inputs: inputs}),
           {:ok, pipeline} <-
             Pipelines.create_pipeline(
               %{
                 repository_id: repository.id,
                 workflow_name: prepared.workflow.name,
                 commit_sha: head.sha,
                 trigger: :workflow_dispatch,
                 actor: actor_id,
                 inputs: prepared.inputs,
                 idempotency_key: "manual:#{repository.id}:#{request_id}",
                 jobs: prepared.workflow.jobs,
                 workflow_revision: revision(file, validated)
               },
               context
             ),
           :ok <-
             audit_launch(
               deps,
               context,
               repository.id,
               path,
               head.sha,
               pipeline.id,
               prepared.inputs
             ) do
        {:ok, %{pipeline: pipeline, branch: head.branch, commit_sha: head.sha}}
      else
        false -> {:error, :untrusted_repository}
        error -> error
      end

    emit(result, started, map_size(inputs))
    result
  end

  def call(_input, %ExecutionContext{}), do: {:error, :forbidden}

  defp resolve_head(deps, repository, branch) when branch in [nil, ""],
    do: deps.source_control.default_branch_head(repository)

  defp resolve_head(deps, repository, branch) when is_binary(branch),
    do: deps.source_control.branch_head(repository, branch)

  defp resolve_head(_deps, _repository, _branch), do: {:error, :invalid_branch}

  defp exact_file(files, path) do
    case Enum.find(files, &(&1.path == path)) do
      nil -> {:error, :manual_workflow_not_found}
      file -> {:ok, file}
    end
  end

  defp valid_head(%{branch: branch, sha: sha} = head)
       when is_binary(branch) and branch != "" and is_binary(sha) do
    if Regex.match?(~r/\A[0-9a-f]{40}\z/, sha),
      do: {:ok, head},
      else: {:error, :invalid_default_branch_head}
  end

  defp valid_head(_head), do: {:error, :invalid_default_branch_head}

  defp resolve(file, files, context) do
    sources = Map.new(files, &{&1.path, &1.content})

    case Workflows.resolve(%{entry_path: file.path, sources: sources}, context) do
      {:ok, validated} -> {:ok, validated}
      {:error, diagnostics} -> {:error, {:invalid_workflow, file.path, diagnostics}}
    end
  end

  defp revision(file, validated) do
    %{
      path: file.path,
      source: file.content,
      sources: Map.delete(validated.sources, file.path)
    }
  end

  defp audit_launch(deps, context, repository_id, path, sha, pipeline_id, inputs) do
    deps.repository.audit_manual_launch(%{
      actor_id: context.actor.id,
      correlation_id: context.correlation_id,
      repository_id: repository_id,
      workflow_path: path,
      commit_sha: sha,
      pipeline_id: pipeline_id,
      input_count: map_size(inputs),
      occurred_at: DateTime.truncate(deps.clock.now(), :microsecond)
    })
  end

  defp emit(result, started, input_count) do
    :telemetry.execute(
      [:robine, :workflow, :manual],
      %{duration: System.monotonic_time() - started, input_count: input_count},
      %{operation: :launch, outcome: if(match?({:ok, _}, result), do: :ok, else: :error)}
    )
  end
end
