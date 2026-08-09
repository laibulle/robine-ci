defmodule Robine.Pipelines.Domain.WorkflowRevision do
  @moduledoc "Immutable workflow source and normalized graph used by one pipeline."

  @enforce_keys [:id, :pipeline_id, :path, :source, :digest, :normalized_graph, :created_at]
  defstruct [
    :id,
    :pipeline_id,
    :path,
    :source,
    :digest,
    :normalized_graph,
    :created_at,
    included_sources: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          pipeline_id: String.t(),
          path: String.t(),
          source: binary(),
          digest: String.t(),
          normalized_graph: map(),
          created_at: DateTime.t(),
          included_sources: %{
            optional(String.t()) => %{required(String.t()) => binary() | String.t()}
          }
        }

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(
        %{
          id: id,
          pipeline_id: pipeline_id,
          path: path,
          source: source,
          normalized_graph: graph,
          created_at: %DateTime{} = created_at
        } = input
      )
      when is_binary(id) and is_binary(pipeline_id) and is_binary(path) and path != "" and
             is_binary(source) and byte_size(source) <= 262_144 and is_map(graph) do
    with {:ok, included_sources} <- included_sources(Map.get(input, :sources, %{})) do
      {:ok,
       %__MODULE__{
         id: id,
         pipeline_id: pipeline_id,
         path: path,
         source: source,
         digest: digest(source),
         normalized_graph: graph,
         created_at: DateTime.truncate(created_at, :microsecond),
         included_sources: included_sources
       }}
    end
  end

  def new(_input), do: {:error, {:invalid_input, :workflow_revision}}

  defp included_sources(sources) when is_map(sources) and map_size(sources) <= 16 do
    valid =
      Enum.all?(sources, fn {path, source} ->
        is_binary(path) and path != "" and byte_size(path) <= 256 and is_binary(source) and
          byte_size(source) <= 262_144
      end)

    total = Enum.reduce(sources, 0, fn {_path, source}, bytes -> bytes + byte_size(source) end)

    if valid and total <= 4_194_304 do
      {:ok,
       Map.new(sources, fn {path, source} ->
         {path, %{"source" => source, "digest" => digest(source)}}
       end)}
    else
      {:error, {:invalid_input, :workflow_revision_sources}}
    end
  end

  defp included_sources(_sources), do: {:error, {:invalid_input, :workflow_revision_sources}}

  defp digest(source), do: :crypto.hash(:sha256, source) |> Base.encode16(case: :lower)
end
