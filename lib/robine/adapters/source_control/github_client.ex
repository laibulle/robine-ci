defmodule Robine.Adapters.SourceControl.GitHubClient do
  @moduledoc false
  @behaviour Robine.Repositories.Ports.GitHub

  @api "https://api.github.com"

  @impl true
  def workflow_files(repository, sha) do
    with {:ok, token} <- token(),
         {:ok, response} <-
           request(:get, workflow_directory_url(repository), token, params: [ref: sha]),
         entries when is_list(entries) <- response.body do
      entries
      |> Enum.filter(&workflow_entry?/1)
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, files} ->
        case request(:get, entry["url"], token, params: [ref: sha]) do
          {:ok, %{body: %{"content" => content, "encoding" => "base64"}}} ->
            case Base.decode64(String.replace(content, ~r/\s/, "")) do
              {:ok, decoded} ->
                {:cont, {:ok, files ++ [%{path: entry["path"], content: decoded}]}}

              :error ->
                {:halt, {:error, :invalid_github_content}}
            end

          {:ok, response} ->
            {:halt, {:error, {:unexpected_github_response, response.status}}}

          error ->
            {:halt, error}
        end
      end)
    else
      %{"message" => "Not Found"} -> {:ok, []}
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_github_response, other}}
    end
  end

  @impl true
  def upsert_check(repository, check) do
    with {:ok, token} <- token(),
         {:ok, _response} <-
           request(:post, "#{@api}/repos/#{repository.full_name}/check-runs", token, json: check) do
      :ok
    end
  end

  defp workflow_directory_url(repository),
    do: "#{@api}/repos/#{repository.owner}/#{repository.name}/contents/.robine-ci/workflows"

  defp workflow_entry?(%{"type" => "file", "name" => name}) do
    String.ends_with?(name, [".yml", ".yaml"])
  end

  defp workflow_entry?(_entry), do: false

  defp token do
    case Application.get_env(:robine, :github_token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :github_token_unavailable}
    end
  end

  defp request(method, url, token, options) do
    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/vnd.github+json"},
      {"x-github-api-version", "2022-11-28"},
      {"user-agent", "Robine-CI"}
    ]

    options = Keyword.merge([method: method, url: url, headers: headers, retry: false], options)

    case Req.request(options) do
      {:ok, %{status: status} = response} when status in 200..299 -> {:ok, response}
      {:ok, %{status: 404, body: %{"message" => "Not Found"}} = response} -> {:ok, response}
      {:ok, response} -> {:error, {:github_http, response.status, response.body}}
      {:error, reason} -> {:error, {:github_transport, reason}}
    end
  end
end
