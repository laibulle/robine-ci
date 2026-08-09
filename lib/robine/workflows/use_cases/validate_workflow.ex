defmodule Robine.Workflows.UseCases.ValidateWorkflow do
  @moduledoc "Decodes and validates one workflow without executing repository code."

  alias Robine.ExecutionContext
  alias Robine.Workflows.Contracts.ValidatedWorkflow
  alias Robine.Workflows.Dependencies
  alias Robine.Workflows.Domain.Validator
  alias Robine.Workflows.Domain.Diagnostic

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, ValidatedWorkflow.t()} | {:error, [Robine.Workflows.Domain.Diagnostic.t()]}
  def call(%{source: source, path: path}, %ExecutionContext{
        dependencies: %{workflows: %Dependencies{} = dependencies}
      })
      when is_binary(source) and is_binary(path) do
    limits = Application.fetch_env!(:robine, :workflow_limits)

    with :ok <- source_size(source, limits),
         {:ok, document, locations} <- decode(dependencies.decoder, source),
         {:ok, workflow, warnings} <- locate(Validator.validate(document, limits), locations) do
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

  defp source_size(source, limits) do
    if byte_size(source) <= Keyword.fetch!(limits, :max_source_bytes) do
      :ok
    else
      {:error,
       [
         Robine.Workflows.Domain.Diagnostic.error(
           "workflow.limit_source_bytes",
           "workflow exceeds #{Keyword.fetch!(limits, :max_source_bytes)} bytes",
           []
         )
       ]}
    end
  end

  defp decode(decoder, source) do
    case decoder.decode(source) do
      {:ok, %{document: document, locations: locations}} ->
        {:ok, document, locations}

      {:ok, document} ->
        {:ok, document, %{}}

      {:error, error} ->
        {:error,
         [
           Diagnostic.error(
             Map.get(error, :code, "yaml.syntax"),
             Map.get(error, :message, "invalid YAML"),
             []
           )
           |> Map.put(:line, Map.get(error, :line))
           |> Map.put(:column, Map.get(error, :column))
         ]}
    end
  end

  defp locate({:ok, workflow, warnings}, locations),
    do: {:ok, workflow, Enum.map(warnings, &Diagnostic.locate(&1, locations))}

  defp locate({:error, diagnostics}, locations),
    do: {:error, Enum.map(diagnostics, &Diagnostic.locate(&1, locations))}
end
