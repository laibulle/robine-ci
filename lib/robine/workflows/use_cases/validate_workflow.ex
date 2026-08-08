defmodule Robine.Workflows.UseCases.ValidateWorkflow do
  @moduledoc "Decodes and validates one workflow without executing repository code."

  alias Robine.ExecutionContext
  alias Robine.Workflows.Contracts.ValidatedWorkflow
  alias Robine.Workflows.Dependencies
  alias Robine.Workflows.Domain.Validator

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, ValidatedWorkflow.t()} | {:error, [Robine.Workflows.Domain.Diagnostic.t()]}
  def call(%{source: source, path: path}, %ExecutionContext{
        dependencies: %{workflows: %Dependencies{} = dependencies}
      })
      when is_binary(source) and is_binary(path) do
    with {:ok, document} <- decode(dependencies.decoder, source),
         {:ok, workflow, warnings} <- Validator.validate(document) do
      {:ok, %ValidatedWorkflow{path: path, workflow: workflow, warnings: warnings}}
    end
  end

  def call(_input, %ExecutionContext{}) do
    {:error,
     [
       Robine.Workflows.Domain.Diagnostic.error(
         "workflow.input",
         "source and path must be strings",
         []
       )
     ]}
  end

  defp decode(decoder, source) do
    case decoder.decode(source) do
      {:ok, document} ->
        {:ok, document}

      {:error, error} ->
        {:error,
         [
           Robine.Workflows.Domain.Diagnostic.error(
             Map.get(error, :code, "yaml.syntax"),
             Map.get(error, :message, "invalid YAML"),
             []
           )
         ]}
    end
  end
end
