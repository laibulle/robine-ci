defmodule Robine.Adapters.Workflow.YamlDecoder do
  @moduledoc false
  @behaviour Robine.Workflows.Ports.Decoder

  @impl true
  def decode(source) when is_binary(source) do
    case YamlElixir.read_from_string(source) do
      {:ok, document} when is_map(document) -> {:ok, document}
      {:ok, _document} -> {:error, %{code: "yaml.document_type", message: "expected a map"}}
      {:error, error} -> {:error, %{code: "yaml.syntax", message: Exception.message(error)}}
    end
  rescue
    error -> {:error, %{code: "yaml.syntax", message: Exception.message(error)}}
  end
end
