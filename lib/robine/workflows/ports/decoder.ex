defmodule Robine.Workflows.Ports.Decoder do
  @moduledoc "Safe YAML decoding capability required by workflow validation."

  @callback decode(String.t()) :: {:ok, map()} | {:error, map()}
end
