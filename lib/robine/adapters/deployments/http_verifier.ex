defmodule Robine.Adapters.Deployments.HttpVerifier do
  @moduledoc false
  @behaviour Robine.Deployments.Ports.Verifier

  @impl true
  def verify(verification, release, options \\ [])

  def verify(verification, release, options)
      when is_map(verification) and is_binary(release) do
    request = Keyword.get(options, :request, &Req.request/1)
    url = fetch(verification, :url)
    expected = fetch(verification, :expected_status)

    with {:ok, response} <- bounded_get(url, request),
         true <- expected_status?(response.status, expected),
         :ok <- verify_version(verification, url, release, request) do
      {:ok, %{status: response.status, release: release}}
    else
      false -> {:error, :unexpected_health_status}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify(_verification, _release, _options), do: {:error, :invalid_verification}

  defp verify_version(verification, base_url, release, request) do
    case fetch(verification, :version_path) do
      nil ->
        :ok

      path when is_binary(path) ->
        with {:ok, url} <- same_origin_url(base_url, path),
             {:ok, response} <- bounded_get(url, request),
             true <- response.status in 200..299,
             {:ok, reported} <- reported_version(response.body),
             true <- reported == release do
          :ok
        else
          false -> {:error, :deployed_version_mismatch}
          {:error, reason} -> {:error, reason}
        end

      _invalid ->
        {:error, :invalid_version_path}
    end
  end

  defp bounded_get(url, request) when is_binary(url) do
    case request.(
           method: :get,
           url: url,
           retry: false,
           redirect: false,
           connect_options: [timeout: 5_000],
           receive_timeout: 10_000,
           max_body_length: 65_536
         ) do
      {:ok, %{status: status, body: body}} when status in 100..599 ->
        if bounded_body?(body),
          do: {:ok, %{status: status, body: body}},
          else: {:error, :verification_response_too_large}

      {:error, _exception} ->
        {:error, :verification_unavailable}

      _invalid ->
        {:error, :invalid_verification_response}
    end
  end

  defp bounded_get(_url, _request), do: {:error, :invalid_verification_url}

  defp expected_status?(status, %{first: first, last: last}), do: status in first..last
  defp expected_status?(status, %{"first" => first, "last" => last}), do: status in first..last
  defp expected_status?(_status, _expected), do: false

  defp same_origin_url(base_url, path) do
    base = URI.parse(base_url)

    if base.scheme in ["http", "https"] and is_binary(base.host) and
         String.starts_with?(path, "/") and not String.starts_with?(path, "//") do
      {:ok, URI.to_string(%URI{base | path: path, query: nil, fragment: nil})}
    else
      {:error, :invalid_version_path}
    end
  end

  defp reported_version(%{"version" => version}) when is_binary(version), do: {:ok, version}
  defp reported_version(%{version: version}) when is_binary(version), do: {:ok, version}

  defp reported_version(body) when is_binary(body) and byte_size(body) <= 65_536 do
    case Jason.decode(body) do
      {:ok, decoded} -> reported_version(decoded)
      _invalid -> {:ok, String.trim(body)}
    end
  end

  defp reported_version(_body), do: {:error, :invalid_version_response}

  defp bounded_body?(body) when is_binary(body), do: byte_size(body) <= 65_536

  defp bounded_body?(body) when is_map(body) or is_list(body),
    do: :erlang.external_size(body) <= 65_536

  defp bounded_body?(_body), do: false

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
