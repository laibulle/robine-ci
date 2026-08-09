defmodule Robine.Adapters.SourceControl.ProviderRequest do
  @moduledoc false

  @default_max_body 2_097_152
  @archive_max_body 100_000_000

  @spec call(:gitlab | :forgejo, atom(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def call(provider, method, path, options \\ [])
      when provider in [:gitlab, :forgejo] and is_atom(method) and is_binary(path) do
    config = Application.get_env(:robine, config_key(provider), [])

    with {:ok, base_url} <- configured_base_url(config),
         {:ok, token} <-
           Robine.Adapters.SourceControl.ProviderCredentials.fetch(provider, :token),
         {:ok, url} <- same_origin_url(base_url, path),
         result <- request(config, provider, method, url, token, options),
         :ok <- emit(provider, method, started(result), result.response),
         {:ok, response} <- normalize_response(provider, result.response),
         :ok <- bounded_body(response.body, Keyword.get(options, :max_body, @default_max_body)) do
      {:ok, response}
    end
  end

  @spec archive_max_body() :: pos_integer()
  def archive_max_body, do: @archive_max_body

  defp request(config, provider, method, url, token, options) do
    started = System.monotonic_time()
    client = Keyword.get(config, :http_client, Robine.Adapters.SourceControl.ReqHttpClient)

    request_options =
      [
        method: method,
        url: url,
        headers: headers(provider, token),
        params: Keyword.get(options, :params, []),
        retry: false,
        redirect: false,
        connect_options: [timeout: 5_000],
        receive_timeout: 15_000
      ]
      |> maybe_put(:json, Keyword.get(options, :json))
      |> maybe_put(:decode_body, Keyword.get(options, :decode_body))

    %{started: started, response: client.request(request_options)}
  end

  defp started(%{started: value}), do: value

  defp configured_base_url(config) do
    case Keyword.get(config, :base_url) do
      value when is_binary(value) and value != "" -> {:ok, String.trim_trailing(value, "/")}
      _missing -> {:error, :source_control_provider_disabled}
    end
  end

  defp same_origin_url(base_url, path) do
    base = URI.parse(base_url)

    if base.scheme in ["https", "http"] and is_binary(base.host) and base.host != "" and
         is_nil(base.userinfo) and is_nil(base.query) and is_nil(base.fragment) and
         String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      {:ok, base_url <> path}
    else
      {:error, :invalid_source_control_origin}
    end
  end

  defp headers(:gitlab, token),
    do: [{"private-token", token}, {"accept", "application/json"}, {"user-agent", "Robine-CI"}]

  defp headers(:forgejo, token),
    do: [
      {"authorization", "token #{token}"},
      {"accept", "application/json"},
      {"user-agent", "Robine-CI"}
    ]

  defp normalize_response(_provider, {:ok, %{status: status} = response}) when status in 200..299,
    do: {:ok, response}

  defp normalize_response(provider, {:ok, %{status: status}}) when status in 300..399,
    do: {:error, {provider, :cross_origin_or_redirect, status}}

  defp normalize_response(provider, {:ok, %{status: status}}),
    do: {:error, {provider, :http, normalize_status(status)}}

  defp normalize_response(provider, {:error, _reason}), do: {:error, {provider, :transport}}

  defp bounded_body(body, maximum) when is_binary(body) and byte_size(body) <= maximum, do: :ok

  defp bounded_body(body, maximum) when is_map(body) or is_list(body) do
    if :erlang.external_size(body) <= maximum,
      do: :ok,
      else: {:error, :source_control_response_too_large}
  end

  defp bounded_body(_body, _maximum), do: {:error, :source_control_response_too_large}

  defp emit(provider, method, started, result) do
    {outcome, status} =
      case result do
        {:ok, %{status: status}} when status in 200..299 -> {:ok, normalize_status(status)}
        {:ok, %{status: status}} -> {:http_error, normalize_status(status)}
        {:error, _reason} -> {:transport_error, :transport}
      end

    :telemetry.execute(
      [:robine, :source_control, :request],
      %{count: 1, duration: System.monotonic_time() - started},
      %{provider: provider, operation: method, outcome: outcome, status: status}
    )
  end

  defp normalize_status(status) when status in 200..299, do: :success
  defp normalize_status(status) when status in 300..399, do: :redirect
  defp normalize_status(status) when status in 400..499, do: :client_error
  defp normalize_status(status) when status in 500..599, do: :server_error
  defp normalize_status(_status), do: :unknown

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)
  defp config_key(:gitlab), do: :gitlab_source_control
  defp config_key(:forgejo), do: :forgejo_source_control
end
