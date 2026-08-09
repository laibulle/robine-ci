defmodule Robine.Pipelines.Dependencies do
  @moduledoc false

  alias Robine.Pipelines.Ports

  @enforce_keys [:unit_of_work, :pipeline_repository, :event_outbox, :clock, :id_generator]
  defstruct [
    :unit_of_work,
    :pipeline_repository,
    :job_repository,
    :log_repository,
    :admission,
    :event_outbox,
    :clock,
    :id_generator
  ]

  @type t :: %__MODULE__{
          unit_of_work: module(),
          pipeline_repository: module(),
          job_repository: module() | nil,
          log_repository: module() | nil,
          admission: module() | nil,
          event_outbox: module(),
          clock: module(),
          id_generator: module()
        }

  @spec validate!(t()) :: :ok
  def validate!(%__MODULE__{} = dependencies) do
    checks = [
      {dependencies.unit_of_work, Ports.UnitOfWork},
      {dependencies.pipeline_repository, Ports.PipelineRepository},
      {dependencies.job_repository, Ports.JobRepository},
      {dependencies.log_repository, Ports.LogRepository},
      {dependencies.admission, Ports.Admission},
      {dependencies.event_outbox, Ports.EventOutbox},
      {dependencies.clock, Ports.Clock},
      {dependencies.id_generator, Ports.IdGenerator}
    ]

    checks
    |> Enum.reject(&(elem(&1, 0) == nil))
    |> Enum.each(fn {implementation, behaviour} ->
      Code.ensure_loaded!(implementation)

      unless behaviour in (implementation.module_info(:attributes)[:behaviour] || []) do
        raise ArgumentError,
              "#{inspect(implementation)} must implement #{inspect(behaviour)}"
      end
    end)

    :ok
  end
end
