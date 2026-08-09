defmodule Robine.Pipelines.Ports.JobRepository do
  @moduledoc "Transactional persistence and claiming capability for pipeline jobs."

  alias Robine.Pipelines.Domain.{Attempt, Job}

  @callback insert_all([Job.t()]) :: :ok | {:error, term()}
  @callback next_queued(pos_integer(), pos_integer()) ::
              {:ok, Job.t()} | {:error, :none | :capacity | term()}
  @callback next_attempt_number(String.t()) :: pos_integer()
  @callback update_job(Job.t()) :: :ok | {:error, term()}
  @callback insert_attempt(Attempt.t()) :: :ok | {:error, term()}
  @callback get_attempt_by_token(String.t()) :: {:ok, Attempt.t()} | {:error, :not_found | term()}
  @callback update_attempt(Attempt.t()) :: :ok | {:error, term()}
  @callback get_job(String.t()) :: {:ok, Job.t()} | {:error, :not_found | term()}
  @callback list_jobs(String.t()) :: {:ok, [Job.t()]} | {:error, term()}
  @callback list_expired_attempts(DateTime.t(), pos_integer()) ::
              {:ok, [Attempt.t()]} | {:error, term()}
  @callback latest_attempt(String.t()) :: {:ok, Attempt.t()} | {:error, :not_found | term()}
  @callback missing_artifact_inputs(String.t(), [map()], DateTime.t()) ::
              {:ok, [map()]} | {:error, term()}
  @callback list_active_attempt_ids() :: {:ok, [String.t()]} | {:error, term()}
  @callback cancellation_requested?(String.t()) :: {:ok, boolean()} | {:error, term()}
  @optional_callbacks missing_artifact_inputs: 3,
                      list_active_attempt_ids: 0,
                      cancellation_requested?: 1
end
