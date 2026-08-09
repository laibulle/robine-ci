defmodule Robine.Workflows.Domain.Composer do
  @moduledoc "Pure bounded composition of exact-revision reusable workflow documents."

  alias Robine.Workflows.Domain.{Diagnostic, ManualInputPolicy, Validator}

  @root_keys ~w(version name on jobs includes)
  @include_keys ~w(path inputs)
  @alias_pattern ~r/\A[a-z][a-z0-9-]{0,19}\z/
  @job_pattern ~r/\A[a-z][a-z0-9_-]{0,62}\z/
  @max_depth 4
  @max_includes 16

  @spec compose(String.t(), %{required(String.t()) => map()}) ::
          {:ok, map()} | {:error, [Diagnostic.t()]}
  def compose(entry_path, documents) when is_binary(entry_path) and is_map(documents) do
    state = %{
      documents: documents,
      jobs: %{},
      job_origins: %{},
      included_paths: MapSet.new(),
      include_count: 0,
      max_depth: 0
    }

    with {:ok, entry} <- fetch_document(entry_path, documents, entry_path, []),
         {:ok, state} <- compose_file(entry_path, [], %{}, [entry_path], 0, true, state) do
      {:ok,
       %{
         document: entry |> Map.delete("includes") |> Map.put("jobs", state.jobs),
         included_paths: state.included_paths |> MapSet.to_list() |> Enum.sort(),
         job_origins: state.job_origins,
         max_depth: state.max_depth
       }}
    end
  end

  def compose(_entry_path, _documents),
    do: {:error, [Diagnostic.error("include.input", "invalid composition input", [])]}

  defp compose_file(path, prefix, submitted, stack, depth, entry?, state) do
    with {:ok, document} <- fetch_document(path, state.documents, path, []),
         :ok <- root_shape(document, path),
         {:ok, inputs} <- call_inputs(document, submitted, path, entry?),
         {:ok, state} <- add_direct_jobs(document, path, prefix, inputs, state),
         {:ok, includes} <- includes(document, path),
         :ok <- unique_paths(includes, path),
         {:ok, state} <- compose_includes(includes, path, prefix, stack, depth, state) do
      {:ok, state}
    end
  end

  defp root_shape(document, path) do
    unknown = Map.keys(document) -- @root_keys

    cond do
      unknown != [] ->
        {:error,
         Enum.map(unknown, fn key ->
           diagnostic(
             "workflow.unknown_key",
             "unknown key #{inspect(key)}",
             [key],
             path
           )
         end)}

      document["version"] != 1 ->
        {:error, [diagnostic("workflow.version", "version must be 1", ["version"], path)]}

      not (is_binary(document["name"]) and document["name"] != "") ->
        {:error, [diagnostic("workflow.name", "name must be a non-empty string", ["name"], path)]}

      not is_map(document["on"]) ->
        {:error, [diagnostic("workflow.triggers", "on must be a map", ["on"], path)]}

      not is_map(Map.get(document, "jobs", %{})) ->
        {:error, [diagnostic("workflow.jobs", "jobs must be a map", ["jobs"], path)]}

      true ->
        :ok
    end
  end

  defp call_inputs(_document, _submitted, _path, true), do: {:ok, %{}}

  defp call_inputs(document, submitted, path, false) do
    call = get_in(document, ["on", "workflow_call"])

    cond do
      not is_map(call) ->
        {:error,
         [
           diagnostic(
             "include.not_reusable",
             "included workflow must declare on.workflow_call",
             ["on", "workflow_call"],
             path
           )
         ]}

      Map.keys(call) -- ["inputs"] != [] ->
        {:error,
         [
           diagnostic(
             "workflow.unknown_key",
             "workflow_call accepts only inputs",
             ["on", "workflow_call"],
             path
           )
         ]}

      true ->
        with {:ok, definitions} <-
               Validator.normalize_input_definitions(
                 Map.get(call, "inputs", %{}),
                 ["on", "workflow_call", "inputs"]
               ),
             {:ok, normalized} <- ManualInputPolicy.normalize(definitions, submitted) do
          {:ok, normalized}
        else
          {:error, diagnostics} when is_list(diagnostics) ->
            {:error, Enum.map(diagnostics, &Diagnostic.source(&1, path))}

          {:error, reason} ->
            {:error, [call_input_diagnostic(reason, path)]}
        end
    end
  end

  defp call_input_diagnostic({:manual_input, id, reason}, path) do
    diagnostic(
      "call_input.#{reason}",
      "workflow call input #{id} is #{reason}",
      ["on", "workflow_call", "inputs", id],
      path
    )
  end

  defp call_input_diagnostic({:manual_inputs_undeclared, names}, path) do
    diagnostic(
      "call_input.undeclared",
      "undeclared workflow call inputs: #{Enum.join(names, ", ")}",
      ["on", "workflow_call", "inputs"],
      path
    )
  end

  defp call_input_diagnostic(_reason, path),
    do:
      diagnostic(
        "call_input.invalid",
        "invalid workflow call inputs",
        ["on", "workflow_call", "inputs"],
        path
      )

  defp add_direct_jobs(document, path, prefix, inputs, state) do
    jobs = Map.get(document, "jobs", %{})
    environment = Map.new(inputs, fn {id, value} -> {call_environment_name(id), value} end)

    jobs
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, state}, fn {id, definition}, {:ok, state} ->
      generated = generated_id(prefix, id)

      with :ok <- generated_job_id(generated, path, id),
           {:ok, transformed} <- transform_job(definition, prefix, environment, path, id),
           false <- Map.has_key?(state.jobs, generated) do
        {:cont,
         {:ok,
          %{
            state
            | jobs: Map.put(state.jobs, generated, transformed),
              job_origins: Map.put(state.job_origins, generated, {path, id})
          }}}
      else
        true ->
          {:halt,
           {:error,
            [
              diagnostic(
                "include.job_collision",
                "generated job ID #{generated} collides with another job",
                ["jobs", id],
                path
              )
            ]}}

        {:error, diagnostics} ->
          {:halt, {:error, List.wrap(diagnostics)}}
      end
    end)
  end

  defp generated_job_id(generated, path, original) do
    if is_binary(original) and Regex.match?(@job_pattern, generated),
      do: :ok,
      else:
        {:error,
         diagnostic(
           "include.job_id",
           "generated job ID #{inspect(generated)} is invalid or exceeds 63 bytes",
           ["jobs", to_string(original)],
           path
         )}
  end

  defp transform_job(definition, prefix, environment, path, id) when is_map(definition) do
    with {:ok, definition} <- inject_environment(definition, environment, path, id) do
      {:ok,
       definition
       |> Map.update("needs", [], &prefix_dependencies(&1, prefix))
       |> Map.update("steps", [], &rewrite_steps(&1, prefix))}
    end
  end

  defp transform_job(definition, _prefix, _environment, _path, _id), do: {:ok, definition}

  defp inject_environment(definition, environment, _path, _id) when map_size(environment) == 0,
    do: {:ok, definition}

  defp inject_environment(definition, environment, path, id) do
    env = Map.get(definition, "env", %{})

    cond do
      not is_map(env) ->
        {:ok, definition}

      collision = Enum.find(Map.keys(environment), &Map.has_key?(env, &1)) ->
        {:error,
         diagnostic(
           "call_input.env_collision",
           "environment #{collision} is reserved for a workflow call input",
           ["jobs", id, "env", collision],
           path
         )}

      true ->
        {:ok, Map.put(definition, "env", Map.merge(env, environment))}
    end
  end

  defp prefix_dependencies(value, []), do: value
  defp prefix_dependencies(value, prefix) when is_binary(value), do: generated_id(prefix, value)

  defp prefix_dependencies(values, prefix) when is_list(values),
    do: Enum.map(values, &if(is_binary(&1), do: generated_id(prefix, &1), else: &1))

  defp prefix_dependencies(value, _prefix), do: value

  defp rewrite_steps(steps, prefix) when is_list(steps) do
    Enum.map(steps, fn
      %{"uses" => "artifacts/download", "with" => %{"from" => from} = options} = step
      when is_binary(from) and prefix != [] ->
        %{step | "with" => Map.put(options, "from", generated_id(prefix, from))}

      step ->
        step
    end)
  end

  defp rewrite_steps(steps, _prefix), do: steps

  defp includes(document, path) do
    case Map.fetch(document, "includes") do
      :error ->
        {:ok, []}

      {:ok, includes} when is_map(includes) and map_size(includes) in 1..8 ->
        includes
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce_while({:ok, []}, fn {alias_name, definition}, {:ok, normalized} ->
          case include(alias_name, definition, path) do
            {:ok, value} -> {:cont, {:ok, normalized ++ [value]}}
            {:error, diagnostic} -> {:halt, {:error, [diagnostic]}}
          end
        end)

      _invalid ->
        {:error,
         [
           diagnostic(
             "include.type",
             "includes must be a map of at most eight entries",
             ["includes"],
             path
           )
         ]}
    end
  end

  defp include(alias_name, definition, owner_path)
       when is_binary(alias_name) and is_map(definition) do
    base = ["includes", alias_name]
    unknown = Map.keys(definition) -- @include_keys

    cond do
      not Regex.match?(@alias_pattern, alias_name) ->
        {:error, diagnostic("include.alias", "invalid include alias", base, owner_path)}

      unknown != [] ->
        {:error,
         diagnostic(
           "include.unknown_key",
           "unknown include key #{inspect(hd(unknown))}",
           base ++ [hd(unknown)],
           owner_path
         )}

      not canonical_path?(definition["path"]) ->
        {:error,
         diagnostic(
           "include.path",
           "include path must be a canonical .robine-ci/workflows/*.yml path",
           base ++ ["path"],
           owner_path
         )}

      not is_map(Map.get(definition, "inputs", %{})) ->
        {:error,
         diagnostic(
           "include.inputs",
           "include inputs must be a map",
           base ++ ["inputs"],
           owner_path
         )}

      true ->
        {:ok,
         %{
           alias: alias_name,
           path: definition["path"],
           inputs: Map.get(definition, "inputs", %{})
         }}
    end
  end

  defp include(alias_name, _definition, owner_path),
    do:
      {:error,
       diagnostic(
         "include.definition",
         "include definition must be a map",
         ["includes", to_string(alias_name)],
         owner_path
       )}

  defp unique_paths(includes, owner_path) do
    paths = Enum.map(includes, & &1.path)

    if length(paths) == length(Enum.uniq(paths)),
      do: :ok,
      else:
        {:error,
         [
           diagnostic(
             "include.duplicate_path",
             "one parent cannot include the same path more than once",
             ["includes"],
             owner_path
           )
         ]}
  end

  defp compose_includes(includes, owner_path, prefix, stack, depth, state) do
    Enum.reduce_while(includes, {:ok, state}, fn include, {:ok, state} ->
      child_depth = depth + 1

      cond do
        child_depth > @max_depth ->
          {:halt,
           {:error,
            [
              diagnostic(
                "include.depth",
                "include depth exceeds #{@max_depth}",
                ["includes", include.alias],
                owner_path
              )
            ]}}

        state.include_count + 1 > @max_includes ->
          {:halt,
           {:error,
            [
              diagnostic(
                "include.count",
                "transitive includes exceed #{@max_includes}",
                ["includes", include.alias],
                owner_path
              )
            ]}}

        include.path in stack ->
          {:halt,
           {:error,
            [
              diagnostic(
                "include.cycle",
                "include cycle reaches #{include.path}",
                ["includes", include.alias, "path"],
                owner_path
              )
            ]}}

        not Map.has_key?(state.documents, include.path) ->
          {:halt,
           {:error,
            [
              diagnostic(
                "include.missing",
                "included workflow #{include.path} is missing from the exact revision",
                ["includes", include.alias, "path"],
                owner_path
              )
            ]}}

        true ->
          state = %{
            state
            | include_count: state.include_count + 1,
              max_depth: max(state.max_depth, child_depth),
              included_paths: MapSet.put(state.included_paths, include.path)
          }

          case compose_file(
                 include.path,
                 prefix ++ [include.alias],
                 include.inputs,
                 stack ++ [include.path],
                 child_depth,
                 false,
                 state
               ) do
            {:ok, state} -> {:cont, {:ok, state}}
            {:error, diagnostics} -> {:halt, {:error, diagnostics}}
          end
      end
    end)
  end

  defp fetch_document(path, documents, owner_path, diagnostic_path) do
    case Map.get(documents, path) do
      document when is_map(document) ->
        {:ok, document}

      _missing ->
        {:error,
         [
           diagnostic(
             "include.missing",
             "included workflow #{path} is missing from the exact revision",
             diagnostic_path,
             owner_path
           )
         ]}
    end
  end

  defp canonical_path?(path) when is_binary(path) and byte_size(path) <= 256 do
    segments = String.split(path, "/", trim: false)

    String.valid?(path) and String.starts_with?(path, ".robine-ci/workflows/") and
      String.ends_with?(path, ".yml") and not String.contains?(path, "\\") and
      Enum.all?(segments, &(&1 not in ["", ".", ".."]))
  end

  defp canonical_path?(_path), do: false

  defp generated_id([], id), do: id
  defp generated_id(prefix, id), do: Enum.join(prefix ++ [id], "--")
  defp call_environment_name(id), do: "ROBINE_CALL_INPUT_" <> String.upcase(id)

  defp diagnostic(code, message, path, source_path),
    do: code |> Diagnostic.error(message, path) |> Diagnostic.source(source_path)
end
