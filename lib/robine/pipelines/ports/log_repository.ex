defmodule Robine.Pipelines.Ports.LogRepository do
  @moduledoc "Durable cursor-based runner log storage."
  @callback insert_all([map()]) :: :ok | {:error, term()}
  @callback list(binary(), non_neg_integer(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
end
