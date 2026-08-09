defmodule Robine.Repositories.UseCases.AcceptGitHubWebhook do
  @moduledoc "Authenticates and durably accepts a GitHub delivery before expensive processing."
  alias Robine.ExecutionContext
  alias Robine.Repositories.UseCases.AcceptSourceControlWebhook

  @spec call(map(), ExecutionContext.t()) :: {:ok, :accepted | :duplicate} | {:error, term()}
  def call(
        %{delivery_id: id, event: event, signature: signature, body: body},
        %ExecutionContext{} = context
      )
      when is_binary(id) and is_binary(event) and is_binary(signature) and is_binary(body) do
    AcceptSourceControlWebhook.call(
      %{
        provider: :github,
        provider_instance: "default",
        delivery_id: id,
        event: event,
        authentication: signature,
        body: body
      },
      context
    )
  end

  def call(_input, %ExecutionContext{}), do: {:error, {:invalid_webhook, :headers}}
end
