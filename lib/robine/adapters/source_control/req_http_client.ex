defmodule Robine.Adapters.SourceControl.ReqHttpClient do
  @moduledoc false
  @behaviour Robine.Adapters.SourceControl.HttpClient

  @impl true
  def request(options), do: Req.request(options)
end
