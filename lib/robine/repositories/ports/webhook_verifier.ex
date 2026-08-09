defmodule Robine.Repositories.Ports.WebhookVerifier do
  @moduledoc "Authenticates an exact raw webhook body for a configured source-control provider."

  @callback verify(:github | :gitlab | :forgejo, binary(), binary()) ::
              :ok | {:error, :invalid_signature | term()}
end
