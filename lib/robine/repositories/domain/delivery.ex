defmodule Robine.Repositories.Domain.Delivery do
  @moduledoc "A durable, deduplicated GitHub delivery."
  @enforce_keys [:id, :event, :payload, :status, :received_at]
  defstruct [:id, :event, :payload, :status, :received_at, :processed_at, :failure]
  @type status :: :pending | :processed | :ignored | :failed
  @type t :: %__MODULE__{
          id: String.t(),
          event: String.t(),
          payload: map(),
          status: status(),
          received_at: DateTime.t(),
          processed_at: DateTime.t() | nil,
          failure: String.t() | nil
        }
end
