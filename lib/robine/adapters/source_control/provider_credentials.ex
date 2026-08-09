defmodule Robine.Adapters.SourceControl.ProviderCredentials do
  @moduledoc false

  alias Robine.Runtime.Dependencies
  alias Robine.Secrets

  @names %{
    {:gitlab, :token} => {"GITLAB_TOKEN", :gitlab_token},
    {:gitlab, :webhook_secret} => {"GITLAB_WEBHOOK_SECRET", :gitlab_webhook_secret},
    {:forgejo, :token} => {"FORGEJO_TOKEN", :forgejo_token},
    {:forgejo, :webhook_secret} => {"FORGEJO_WEBHOOK_SECRET", :forgejo_webhook_secret}
  }

  @spec fetch(:gitlab | :forgejo, :token | :webhook_secret) ::
          {:ok, binary()} | {:error, term()}
  def fetch(provider, kind) do
    with {:ok, {secret_name, environment_key}} <- Map.fetch(@names, {provider, kind}) do
      context =
        Dependencies.context(
          %{id: "system:#{provider}-credentials", role: :administrator},
          "#{provider}-credentials:#{kind}"
        )

      case Secrets.resolve_instance_secrets(%{names: [secret_name]}, context) do
        {:ok, %{^secret_name => value}} -> {:ok, value}
        {:error, {:secrets_missing, _names}} -> configured_fallback(environment_key)
        {:error, reason} -> fallback_or_error(environment_key, reason)
      end
    else
      :error -> {:error, :unsupported_source_control_credential}
    end
  rescue
    error -> fallback_or_error(environment_key(provider, kind), error.__struct__)
  end

  defp environment_key(provider, kind) do
    case Map.get(@names, {provider, kind}) do
      {_secret_name, key} -> key
      nil -> :unsupported_source_control_credential
    end
  end

  defp fallback_or_error(environment_key, reason) do
    case configured_fallback(environment_key) do
      {:ok, value} -> {:ok, value}
      {:error, :credential_unavailable} -> {:error, reason}
    end
  end

  defp configured_fallback(environment_key) do
    case Application.get_env(:robine, environment_key) do
      value when is_binary(value) and byte_size(value) in 8..16_384 -> {:ok, value}
      _value -> {:error, :credential_unavailable}
    end
  end
end
