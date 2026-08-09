defmodule Robine.Execution.Contracts.Specification do
  @moduledoc "Versioned, framework-free execution contract shared by CI and local execution."

  alias Robine.Execution.Contracts.{Service, Step}

  @derive {Inspect, except: [:secrets]}
  @enforce_keys [:version, :attempt_id, :image, :workspace, :shell, :steps, :timeout_ms]
  defstruct [
    :version,
    :attempt_id,
    :image,
    :workspace,
    :shell,
    :steps,
    :timeout_ms,
    :source_path,
    env: %{},
    secrets: %{},
    services: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          version: 1,
          attempt_id: String.t(),
          image: String.t(),
          workspace: String.t(),
          shell: String.t(),
          steps: [Step.t()],
          timeout_ms: pos_integer(),
          source_path: String.t() | nil,
          env: %{optional(String.t()) => String.t()},
          secrets: %{optional(String.t()) => String.t()},
          services: [Service.t()],
          metadata: map()
        }
end
