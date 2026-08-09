defmodule Robine.Adapters.SourceControl.GitHubAppTokenCache do
  @moduledoc false
  use GenServer

  @api "https://api.github.com"
  @refresh_margin_seconds 60

  def start_link(_options), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  def token(installation_id), do: GenServer.call(__MODULE__, {:token, installation_id}, 30_000)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:token, installation_id}, _from, state) do
    now = DateTime.utc_now()

    case Map.get(state, installation_id) do
      %{token: token, expires_at: expires_at} ->
        if DateTime.compare(
             expires_at,
             DateTime.add(now, @refresh_margin_seconds, :second)
           ) == :gt do
          {:reply, {:ok, token}, state}
        else
          refresh(installation_id, now, state)
        end

      _expired_or_missing ->
        refresh(installation_id, now, state)
    end
  end

  defp refresh(installation_id, now, state) do
    case fetch_token(installation_id, now) do
      {:ok, entry} -> {:reply, {:ok, entry.token}, Map.put(state, installation_id, entry)}
      {:error, reason} -> {:reply, {:error, reason}, Map.delete(state, installation_id)}
    end
  end

  defp fetch_token(installation_id, now) do
    with {:ok, jwt} <- app_jwt(now),
         {:ok, response} <-
           Req.post("#{@api}/app/installations/#{installation_id}/access_tokens",
             headers: headers(jwt),
             retry: false
           ),
         true <- response.status in 200..299,
         %{"token" => token, "expires_at" => expires_at} <- response.body,
         {:ok, expires_at, _offset} <- DateTime.from_iso8601(expires_at) do
      {:ok, %{token: token, expires_at: expires_at}}
    else
      false -> {:error, :github_app_token_http_error}
      {:ok, response} -> {:error, {:github_app_token_http, response.status}}
      {:error, reason} -> {:error, {:github_app_token, reason}}
      _ -> {:error, :invalid_github_app_token_response}
    end
  end

  defp app_jwt(now) do
    with app_id when is_binary(app_id) and app_id != "" <-
           Application.get_env(:robine, :github_app_id),
         pem when is_binary(pem) and pem != "" <-
           Application.get_env(:robine, :github_app_private_key),
         [entry] <- :public_key.pem_decode(pem),
         key <- :public_key.pem_entry_decode(entry) do
      issued_at = DateTime.to_unix(now) - 60
      header = encode(%{"alg" => "RS256", "typ" => "JWT"})
      payload = encode(%{"iat" => issued_at, "exp" => issued_at + 540, "iss" => app_id})
      signing_input = header <> "." <> payload

      signature =
        :public_key.sign(signing_input, :sha256, key) |> Base.url_encode64(padding: false)

      {:ok, signing_input <> "." <> signature}
    else
      _ -> {:error, :github_app_credentials_unavailable}
    end
  rescue
    _error -> {:error, :invalid_github_app_private_key}
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp headers(token),
    do: [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "Robine-CI"}
    ]
end
