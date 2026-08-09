defmodule Robine.Adapters.Workflow.YamlDecoder do
  @moduledoc false
  @behaviour Robine.Workflows.Ports.Decoder

  @impl true
  def decode(source) when is_binary(source) do
    started = System.monotonic_time()

    result =
      try do
        do_decode(source)
      rescue
        error -> {:error, %{code: "yaml.syntax", message: Exception.message(error)}}
      end

    emit_validation(result, started)
    result
  end

  defp do_decode(source) do
    case YamlElixir.read_from_string(source) do
      {:ok, document} when is_map(document) ->
        {:ok, %{document: document, locations: locations(source)}}

      {:ok, _document} ->
        {:error, %{code: "yaml.document_type", message: "expected a map"}}

      {:error, error} ->
        {fallback_line, fallback_column} = end_position(source)

        {:error,
         %{
           code: "yaml.syntax",
           message: Exception.message(error),
           line: Map.get(error, :line) || fallback_line,
           column: Map.get(error, :column) || fallback_column
         }}
    end
  end

  defp emit_validation(result, started) do
    {outcome, version} =
      case result do
        {:ok, %{document: document}} -> {:ok, bounded_version(document["version"])}
        {:error, _diagnostic} -> {:error, :unknown}
      end

    :telemetry.execute(
      [:robine, :workflow, :validation],
      %{count: 1, duration: System.monotonic_time() - started},
      %{outcome: outcome, schema_version: version}
    )
  end

  defp bounded_version(version) when version in [1], do: version
  defp bounded_version(_version), do: :unknown

  defp locations(source) do
    options = [detailed_constr: true, str_node_as_binary: true, keep_duplicate_keys: true]

    source
    |> :yamerl_constr.string(options)
    |> List.last()
    |> index([], %{})
  catch
    _kind, _reason -> %{}
  end

  defp index({:yamerl_doc, node}, path, locations), do: index(node, path, locations)

  defp index({:yamerl_map, :yamerl_node_map, _tag, presentation, pairs}, path, locations) do
    locations = put_location(locations, path, presentation)

    Enum.reduce(pairs, locations, fn {key_node, value_node}, acc ->
      key = scalar_value(key_node)
      child_path = path ++ [key]

      acc = put_location(acc, child_path, presentation(key_node))
      index(value_node, child_path, acc)
    end)
  end

  defp index(
         {:yamerl_seq, :yamerl_node_seq, _tag, presentation, entries, _count},
         path,
         locations
       ) do
    locations = put_location(locations, path, presentation)

    entries
    |> Enum.with_index()
    |> Enum.reduce(locations, fn {entry, position}, acc ->
      child_path = path ++ [position]

      acc = put_location(acc, child_path, presentation(entry))
      index(entry, child_path, acc)
    end)
  end

  defp index(node, path, locations),
    do: put_location(locations, path, presentation(node))

  defp presentation(node) when is_tuple(node) and tuple_size(node) >= 4, do: elem(node, 3)
  defp presentation(_node), do: []

  defp scalar_value(node) when is_tuple(node), do: elem(node, tuple_size(node) - 1)

  defp put_location(locations, path, presentation) do
    case {Keyword.get(presentation, :line), Keyword.get(presentation, :column)} do
      {line, column} when is_integer(line) and is_integer(column) ->
        Map.put_new(locations, path, %{line: line, column: column})

      _ ->
        locations
    end
  end

  defp end_position(source) do
    lines = String.split(source, "\n", trim: false)
    {length(lines), String.length(List.last(lines)) + 1}
  end
end
