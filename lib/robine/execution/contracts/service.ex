defmodule Robine.Execution.Contracts.Service do
  @moduledoc "Inspect-safe service configuration resolved for one attempt."

  @derive {Inspect, except: [:secret_env]}
  @enforce_keys [:id, :image]
  defstruct [
    :id,
    :image,
    :user,
    :readiness,
    privileged: false,
    env: %{},
    secret_env: %{},
    command: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          image: String.t(),
          user: String.t() | nil,
          privileged: boolean(),
          env: %{optional(String.t()) => String.t()},
          secret_env: %{optional(String.t()) => String.t()},
          command: [String.t()],
          readiness: %{tcp: 1..65_535, timeout_ms: 1_000..120_000} | nil
        }
end
