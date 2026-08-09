defmodule Robine.Adapters.SourceControl.HttpClient do
  @moduledoc false
  @callback request(keyword()) :: {:ok, map()} | {:error, term()}
end
