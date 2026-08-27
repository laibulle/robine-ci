defmodule Robine.Publications.UseCases.ResolveLatest do
  @moduledoc "Resolves a public stable latest alias without exposing private repository identity."
  alias Robine.ExecutionContext
  alias Robine.Publications.Dependencies
  alias Robine.Publications.Domain.RepositoryPolicy

  @filename ~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/

  def call(%{public_slug: slug, filename: filename}, %ExecutionContext{
        dependencies: %{publications: %Dependencies{} = deps}
      }) do
    with true <- RepositoryPolicy.valid_slug?(slug),
         true <- is_binary(filename) and Regex.match?(@filename, filename),
         {:ok, publication} <- deps.repository.find_latest_published(slug, filename),
         true <- safe_public_url?(publication.public_url) do
      {:ok, publication}
    else
      _reason -> {:error, :not_found}
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, :not_found}

  defp safe_public_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" -> true
      _uri -> false
    end
  end

  defp safe_public_url?(_url), do: false
end
