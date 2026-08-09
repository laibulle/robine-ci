defmodule Robine.Transfers.Ports.Archive do
  @moduledoc "Bounded source archive creation capability."
  @callback create_source(map()) :: {:ok, binary()} | {:error, term()}
end
