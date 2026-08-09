defmodule Robine.Adapters.Storage.ExAwsReqClient do
  @moduledoc false
  @behaviour ExAws.Request.HttpClient

  @impl true
  def request(method, url, body, headers, http_options) do
    options =
      [
        method: method,
        url: url,
        headers: headers,
        decode_body: false,
        retry: false,
        receive_timeout: receive_timeout(http_options)
      ]
      |> maybe_body(method, body)

    case Req.request(options) do
      {:ok, response} ->
        {:ok,
         %{
           status_code: response.status,
           headers: Req.get_headers_list(response),
           body: response.body
         }}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

  defp maybe_body(options, method, _body) when method in [:get, :head], do: options
  defp maybe_body(options, _method, body), do: Keyword.put(options, :body, body)

  defp receive_timeout(options) do
    Keyword.get(options, :receive_timeout, Keyword.get(options, :recv_timeout, 30_000))
  end
end
