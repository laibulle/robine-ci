defmodule Robine.Workflows.Domain.Workflow do
  @moduledoc "A validated versioned workflow and deterministic job order."

  alias Robine.Workflows.Domain.Job

  @enforce_keys [:version, :name, :triggers, :jobs, :order]
  defstruct [:version, :name, :triggers, :jobs, :order]

  @type t :: %__MODULE__{
          version: 1,
          name: String.t(),
          triggers: map(),
          jobs: %{required(String.t()) => Job.t()},
          order: [String.t()]
        }
end
