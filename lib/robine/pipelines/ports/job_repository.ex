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
end
