defmodule Robine.Workflows.Domain.Job do
  @moduledoc "A normalized container job in a workflow graph."

  alias Robine.Workflows.Domain.Step

  @enforce_keys [:id, :image, :needs, :steps]
  defstruct [
    :id,
    :image,
    :needs,
    :steps,
    :timeout,
    :base_id,
    condition: :success,
    shell: "/bin/sh",
    env: %{},
    secrets: [],
    services: %{},
    runs_on: ["docker"],
    matrix: %{},
    matrix_values: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          image: String.t(),
          needs: [String.t()],
          steps: [Step.t()],
          timeout: String.t() | nil,
          base_id: String.t() | nil,
          condition: :success | :failure | :always,
          shell: String.t(),
          env: %{optional(String.t()) => String.t()},
          secrets: [String.t()],
          services: %{optional(String.t()) => Robine.Workflows.Domain.Service.t()},
          runs_on: [String.t()],
          matrix: %{optional(String.t()) => [String.t()]},
          matrix_values: %{optional(String.t()) => String.t()}
        }
end
