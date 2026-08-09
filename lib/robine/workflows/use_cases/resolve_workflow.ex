defmodule Robine.Workflows.UseCases.ResolveWorkflow do
  @moduledoc "Resolves and validates one exact-revision multi-file workflow graph."

  alias Robine.ExecutionContext
  alias Robine.Workflows.Contracts.ValidatedWorkflow
  alias Robine.Workflows.Dependencies
  alias Robine.Workflows.Domain.{Composer, Diagnostic, Validator}

  @max_reachable_sources 17

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, ValidatedWorkflow.t()} | {:error, [Diagnostic.t()]}
  def call(
        %{entry_path: entry_path, sources: sources},
        %ExecutionContext{dependencies: %{workflows: %Dependencies{} = dependencies}}
      )
      when is_binary(entry_path) and is_map(sources) do
    started = System.monotonic_time()
    limits = Application.fetch_env!(:robine, :workflow_limits)

    result =
      with {:ok, decoded, locations} <-
             decode_reachable(entry_path, sources, dependencies.decoder, limits) do
        compose_and_validate(entry_path, sources, decoded, locations, limits)
      else
        {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      end

    emit(result, started)

    case result do
      {:ok, validated, _composed} -> {:ok, validated}
      {:error, diagnostics} -> {:error, diagnostics}
    end
  end

  def call(_input, %ExecutionContext{}) do
    {:error,
     [
       Diagnostic.error(
         "include.input",
         "entry_path and sources must describe an exact workflow source set",
         []
       )
     ]}
  end

  defp decode_reachable(entry_path, sources, decoder, limits) do
    if is_binary(Map.get(sources, entry_path)) do
      walk_sources([entry_path], sources, decoder, limits, %{}, %{})
    else
      {:error,
       [
         Diagnostic.error(
           "include.entry_missing",
           "entry workflow source is missing from the exact revision",
           []
         )
         |> Diagnostic.source(entry_path)
       ]}
    end
  end

  defp compose_and_validate(entry_path, sources, decoded, locations, limits) do
    case Composer.compose(entry_path, decoded) do
      {:ok, composed} ->
        case Validator.validate(composed.document, limits) do
          {:ok, workflow, warnings} ->
            used_paths = [entry_path | composed.included_paths]
            used_sources = Map.take(sources, used_paths)

            located_warnings =
              Enum.map(warnings, &locate(&1, entry_path, composed.job_origins, locations))

            {:ok,
             %ValidatedWorkflow{
               path: entry_path,
               workflow: workflow,
               warnings: located_warnings,
               sources: used_sources
             }, composed}

          {:error, diagnostics} ->
            {:error,
             Enum.map(diagnostics, &locate(&1, entry_path, composed.job_origins, locations))}
        end

      {:error, diagnostics} ->
        {:error, Enum.map(diagnostics, &locate(&1, entry_path, %{}, locations))}
    end
  end

  defp walk_sources([], _sources, _decoder, _limits, documents, locations),
    do: {:ok, documents, locations}

  defp walk_sources([path | rest], sources, decoder, limits, documents, locations) do
    cond do
      Map.has_key?(documents, path) ->
        walk_sources(rest, sources, decoder, limits, documents, locations)

      map_size(documents) >= @max_reachable_sources ->
        {:error,
         [
           Diagnostic.error(
             "include.count",
             "reachable workflow sources exceed #{@max_reachable_sources}",
             ["includes"]
           )
           |> Diagnostic.source(path)
         ]}

      true ->
        case Map.get(sources, path) do
          source when is_binary(source) ->
            with :ok <- source_size(source, limits, path),
                 {:ok, document, source_locations} <- decode(decoder, source, path) do
              children = included_paths(document)

              walk_sources(
                rest ++ children,
                sources,
                decoder,
                limits,
                Map.put(documents, path, document),
                Map.put(locations, path, source_locations)
              )
            end

          _missing ->
            walk_sources(rest, sources, decoder, limits, documents, locations)
        end
    end
  end

  defp included_paths(document) when is_map(document) do
    case Map.get(document, "includes") do
      includes when is_map(includes) ->
        includes
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn
          {_alias, %{"path" => path}} when is_binary(path) -> [path]
          _invalid -> []
        end)

      _missing ->
        []
    end
  end

  defp included_paths(_document), do: []

  defp source_size(source, limits, path) do
    maximum = Keyword.fetch!(limits, :max_source_bytes)

    if byte_size(source) <= maximum do
      :ok
    else
      {:error,
       [
         Diagnostic.error(
           "workflow.limit_source_bytes",
           "workflow exceeds #{maximum} bytes",
           []
         )
         |> Diagnostic.source(path)
       ]}
    end
  end

  defp decode(decoder, source, path) do
    case decoder.decode(source) do
      {:ok, %{document: document, locations: locations}} ->
        {:ok, document, locations}

      {:ok, document} ->
        {:ok, document, %{}}

      {:error, error} ->
        diagnostic =
          Diagnostic.error(
            Map.get(error, :code, "yaml.syntax"),
            Map.get(error, :message, "invalid YAML"),
            []
          )
          |> Map.put(:line, Map.get(error, :line))
          |> Map.put(:column, Map.get(error, :column))
          |> Diagnostic.source(path)

        {:error, [diagnostic]}
    end
  end

  defp locate(%Diagnostic{source_path: source_path} = diagnostic, _entry, _origins, locations)
       when is_binary(source_path) do
    Diagnostic.locate(diagnostic, Map.get(locations, source_path, %{}))
  end

  defp locate(%Diagnostic{path: ["jobs", id | rest]} = diagnostic, entry, origins, locations) do
    case Map.get(origins, id) do
      {source_path, original_id} ->
        diagnostic
        |> Map.put(:path, ["jobs", original_id | rest])
        |> Diagnostic.source(source_path)
        |> Diagnostic.locate(Map.get(locations, source_path, %{}))

      nil ->
        diagnostic
        |> Diagnostic.source(entry)
        |> Diagnostic.locate(Map.get(locations, entry, %{}))
    end
  end

  defp locate(diagnostic, entry, _origins, locations) do
    diagnostic
    |> Diagnostic.source(entry)
    |> Diagnostic.locate(Map.get(locations, entry, %{}))
  end

  defp emit(result, started) do
    {outcome, files, depth, jobs} =
      case result do
        {:ok, validated, composed} ->
          {:ok, map_size(validated.sources), composed.max_depth,
           map_size(validated.workflow.jobs)}

        {:error, _diagnostics} ->
          {:error, 0, 0, 0}
      end

    :telemetry.execute(
      [:robine, :workflow, :composition],
      %{
        duration: System.monotonic_time() - started,
        source_files: files,
        max_depth: depth,
        composed_jobs: jobs
      },
      %{outcome: outcome}
    )
  end
end
