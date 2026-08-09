defmodule Robine.Workflows.Domain.Service do
  @moduledoc "A normalized attempt-scoped service declared by a workflow job."

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

  @type readiness :: %{tcp: 1..65_535, timeout_ms: 1_000..120_000}
  @type t :: %__MODULE__{
          id: String.t(),
          image: String.t(),
          user: String.t() | nil,
          privileged: boolean(),
          env: %{optional(String.t()) => String.t()},
          secret_env: %{optional(String.t()) => String.t()},
          command: [String.t()],
          readiness: readiness() | nil
        }
end
