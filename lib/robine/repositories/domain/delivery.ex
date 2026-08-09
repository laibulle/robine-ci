defmodule Robine.Repositories.Domain.Delivery do
  @moduledoc "A durable, provider-namespaced source-control delivery."
  @enforce_keys [
    :id,
    :provider,
    :provider_instance,
    :provider_delivery_id,
    :event,
    :payload,
    :status,
    :received_at
  ]
  defstruct [
    :id,
    :provider,
    :provider_instance,
    :provider_delivery_id,
    :event,
    :payload,
    :status,
    :received_at,
    :processed_at,
    :failure
  ]

  @type status :: :pending | :processed | :ignored | :failed
  @type t :: %__MODULE__{
          id: String.t(),
          provider: :github | :gitlab | :forgejo,
          provider_instance: String.t(),
          provider_delivery_id: String.t(),
          event: String.t(),
          payload: map(),
          status: status(),
          received_at: DateTime.t(),
          processed_at: DateTime.t() | nil,
          failure: String.t() | nil
        }
end
