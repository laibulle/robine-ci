defmodule Robine.Repositories.UseCases.AcceptSourceControlWebhook do
  @moduledoc "Authenticates and durably accepts one provider-namespaced source-control delivery."

  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.Delivery

  @providers [:github, :gitlab, :forgejo]
  @max_body_bytes 1_048_576

  @spec call(map(), ExecutionContext.t()) ::
          {:ok, :accepted | :duplicate} | {:error, term()}
  def call(input, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{repositories: %Dependencies{} = dependencies}
      })
      when is_map(input) do
    provider = Map.get(input, :provider)
    provider_instance = Map.get(input, :provider_instance, "default")
    provider_delivery_id = Map.get(input, :delivery_id)
    event = Map.get(input, :event)
    authentication = Map.get(input, :authentication)
    body = Map.get(input, :body)

    with :ok <-
           valid_headers(
             provider,
             provider_instance,
             provider_delivery_id,
             event,
             authentication,
             body
           ),
         :ok <- dependencies.webhook_verifier.verify(provider, body, authentication),
         {:ok, payload} <- Jason.decode(body),
         true <- is_map(payload),
         delivery = %Delivery{
           id: delivery_id(provider, provider_instance, provider_delivery_id),
           provider: provider,
           provider_instance: provider_instance,
           provider_delivery_id: provider_delivery_id,
           event: event,
           payload: payload,
           status: :pending,
           received_at: DateTime.truncate(dependencies.clock.now(), :microsecond)
         } do
      dependencies.repository.accept_delivery(delivery)
    else
      false -> {:error, {:invalid_webhook, :payload}}
      {:error, %Jason.DecodeError{}} -> {:error, {:invalid_webhook, :json}}
      {:error, _reason} = error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, {:invalid_webhook, :headers}}

  defp valid_headers(provider, instance, delivery_id, event, authentication, body) do
    if provider in @providers and is_binary(instance) and byte_size(instance) in 1..64 and
         is_binary(delivery_id) and byte_size(delivery_id) in 1..255 and is_binary(event) and
         byte_size(event) in 1..64 and is_binary(authentication) and
         byte_size(authentication) in 1..16_384 and is_binary(body) and
         byte_size(body) <= @max_body_bytes do
      :ok
    else
      {:error, {:invalid_webhook, :headers}}
    end
  end

  defp delivery_id(:github, "default", provider_delivery_id), do: provider_delivery_id

  defp delivery_id(provider, instance, provider_delivery_id) do
    digest =
      :crypto.hash(:sha256, provider_delivery_id)
      |> Base.url_encode64(padding: false)

    "#{provider}:#{instance}:#{digest}"
  end
end
