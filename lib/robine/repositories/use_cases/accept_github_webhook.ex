defmodule Robine.Repositories.UseCases.AcceptGitHubWebhook do
  @moduledoc "Authenticates and durably accepts a GitHub delivery before expensive processing."
  alias Robine.ExecutionContext
  alias Robine.Repositories.Dependencies
  alias Robine.Repositories.Domain.Delivery

  @spec call(map(), ExecutionContext.t()) :: {:ok, :accepted | :duplicate} | {:error, term()}
  def call(%{delivery_id: id, event: event, signature: signature, body: body}, %ExecutionContext{
        actor: %{role: :administrator},
        dependencies: %{repositories: %Dependencies{} = deps}
      })
      when is_binary(id) and is_binary(event) and is_binary(signature) and is_binary(body) do
    with :ok <- deps.signature_verifier.verify(body, signature),
         {:ok, payload} <- Jason.decode(body),
         true <- is_map(payload),
         delivery = %Delivery{
           id: id,
           event: event,
           payload: payload,
           status: :pending,
           received_at: DateTime.truncate(deps.clock.now(), :microsecond)
         } do
      deps.repository.accept_delivery(delivery)
    else
      false -> {:error, {:invalid_webhook, :payload}}
      {:error, %Jason.DecodeError{}} -> {:error, {:invalid_webhook, :json}}
      error -> error
    end
  end

  def call(_input, %ExecutionContext{}), do: {:error, {:invalid_webhook, :headers}}
end
