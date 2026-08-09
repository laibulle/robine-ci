defmodule Robine.Adapters.SourceControl.GitHubCredentials do
  @moduledoc false

  alias Robine.Runtime.Dependencies
  alias Robine.Secrets

  @names %{
    private_key: {"GITHUB_APP_PRIVATE_KEY", :github_app_private_key},
    webhook_secret: {"GITHUB_WEBHOOK_SECRET", :github_webhook_secret}
  }

  @spec fetch(:private_key | :webhook_secret) :: {:ok, binary()} | {:error, term()}
  def fetch(kind) do
    {secret_name, environment_key} = Map.fetch!(@names, kind)

    context =
      Dependencies.context(
        %{id: "system:github-credentials", role: :administrator},
        "github-credentials:#{kind}"
      )

    case Secrets.resolve_instance_secrets(%{names: [secret_name]}, context) do
      {:ok, %{^secret_name => value}} -> {:ok, value}
      {:error, {:secrets_missing, _names}} -> configured_fallback(environment_key)
      {:error, reason} -> fallback_or_error(environment_key, reason)
    end
  rescue
    error -> fallback_or_error(Map.fetch!(@names, kind) |> elem(1), error.__struct__)
  end

  defp fallback_or_error(environment_key, reason) do
    case configured_fallback(environment_key) do
      {:ok, value} -> {:ok, value}
      {:error, :credential_unavailable} -> {:error, reason}
    end
  end

  defp configured_fallback(environment_key) do
    case Application.get_env(:robine, environment_key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, :credential_unavailable}
    end
  end
end
