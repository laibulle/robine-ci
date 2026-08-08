defmodule Robine.Adapters.Persistence.Postgres.JobRepository do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.JobRepository

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.Attempt, as: AttemptSchema
  alias Robine.Adapters.Persistence.Postgres.Schemas.Job, as: JobSchema
  alias Robine.Adapters.Persistence.Postgres.Schemas.Pipeline, as: PipelineSchema
  alias Robine.Repo

  @active_attempts [:queued, :preparing, :running, :cancelling]

  @impl true
  def insert_all(jobs) do
    Enum.reduce_while(jobs, :ok, fn job, :ok ->
      job
      |> Map.from_struct()
      |> Map.put(:execution_spec, job.execution)
      |> then(&JobSchema.changeset(%JobSchema{}, &1))
      |> Repo.insert()
      |> case do
        {:ok, _schema} -> {:cont, :ok}
        {:error, changeset} -> {:halt, {:error, {:job_persistence, changeset}}}
      end
    end)
  end

  @impl true
  def next_queued(global_limit, repository_limit) do
    active =
      Repo.aggregate(
        from(attempt in AttemptSchema, where: attempt.status in ^@active_attempts),
        :count
      )

    if active >= global_limit do
      {:error, :capacity}
    else
      find_fair_job(repository_limit)
    end
  end

  defp find_fair_job(repository_limit) do
    candidates =
      Repo.all(
        from job in JobSchema,
          join: pipeline in PipelineSchema,
          on: pipeline.id == job.pipeline_id,
          where: job.status == :queued and pipeline.status in [:queued, :running],
          order_by: [asc: pipeline.inserted_at, asc: job.position],
          limit: 20,
          lock: "FOR UPDATE SKIP LOCKED",
          select: {job, pipeline.repository_id}
      )

    Enum.find_value(candidates, {:error, :none}, fn {job, repository_id} ->
      active_for_repository =
        Repo.aggregate(
          from(attempt in AttemptSchema,
            join: active_job in JobSchema,
            on: active_job.id == attempt.job_id,
            join: pipeline in PipelineSchema,
            on: pipeline.id == active_job.pipeline_id,
            where:
              pipeline.repository_id == ^repository_id and attempt.status in ^@active_attempts
          ),
          :count
        )

      if active_for_repository < repository_limit, do: {:ok, to_domain(job)}, else: nil
    end)
  end

  @impl true
  def next_attempt_number(job_id) do
    (Repo.aggregate(
       from(attempt in AttemptSchema, where: attempt.job_id == ^job_id),
       :max,
       :number
     ) ||
       0) + 1
  end

  @impl true
  def update_job(%Robine.Pipelines.Domain.Job{} = job) do
    case Repo.get(JobSchema, job.id) do
      nil ->
        {:error, :not_found}

      schema ->
        attributes = job |> Map.from_struct() |> Map.put(:execution_spec, job.execution)
        persist_attributes(schema, JobSchema, attributes, :job_persistence)
    end
  end

  @impl true
  def insert_attempt(%Robine.Pipelines.Domain.Attempt{} = attempt) do
    attempt
    |> Map.from_struct()
    |> then(&AttemptSchema.changeset(%AttemptSchema{}, &1))
    |> Repo.insert()
    |> case do
      {:ok, _schema} -> :ok
      {:error, changeset} -> {:error, {:attempt_persistence, changeset}}
    end
  end

  @impl true
  def get_attempt_by_token(token) when is_binary(token) do
    case Repo.one(from attempt in AttemptSchema, where: attempt.idempotency_token == ^token) do
      nil -> {:error, :not_found}
      schema -> {:ok, attempt_to_domain(schema)}
    end
  end

  @impl true
  def update_attempt(%Robine.Pipelines.Domain.Attempt{} = attempt) do
    case Repo.get(AttemptSchema, attempt.id) do
      nil -> {:error, :not_found}
      schema -> persist(schema, AttemptSchema, attempt, :attempt_persistence)
    end
  end

  @impl true
  def get_job(id) when is_binary(id) do
    case Repo.get(JobSchema, id) do
      nil -> {:error, :not_found}
      schema -> {:ok, to_domain(schema)}
    end
  end

  @impl true
  def list_jobs(pipeline_id) when is_binary(pipeline_id) do
    jobs =
      Repo.all(
        from job in JobSchema,
          where: job.pipeline_id == ^pipeline_id,
          order_by: [asc: job.position]
      )

    {:ok, Enum.map(jobs, &to_domain/1)}
  end

  @impl true
  def list_expired_attempts(now, limit) do
    attempts =
      Repo.all(
        from attempt in AttemptSchema,
          where: attempt.status in ^@active_attempts and attempt.lease_expires_at < ^now,
          order_by: [asc: attempt.lease_expires_at],
          limit: ^limit
      )

    {:ok, Enum.map(attempts, &attempt_to_domain/1)}
  end

  defp persist(schema, schema_module, domain, error_tag) do
    schema
    |> schema_module.changeset(Map.from_struct(domain))
    |> Repo.update()
    |> case do
      {:ok, _schema} -> :ok
      {:error, changeset} -> {:error, {error_tag, changeset}}
    end
  end

  defp to_domain(schema) do
    struct!(Robine.Pipelines.Domain.Job, %{
      id: schema.id,
      pipeline_id: schema.pipeline_id,
      job_key: schema.job_key,
      status: schema.status,
      needs: schema.needs,
      position: schema.position,
      execution: schema.execution_spec
    })
  end

  defp attempt_to_domain(schema) do
    struct!(Robine.Pipelines.Domain.Attempt, %{
      id: schema.id,
      job_id: schema.job_id,
      number: schema.number,
      idempotency_token: schema.idempotency_token,
      status: schema.status,
      lease_expires_at: schema.lease_expires_at,
      last_sequence: schema.last_sequence,
      result_reason: schema.result_reason
    })
  end

  defp persist_attributes(schema, schema_module, attributes, error_tag) do
    schema
    |> schema_module.changeset(attributes)
    |> Repo.update()
    |> case do
      {:ok, _schema} -> :ok
      {:error, changeset} -> {:error, {error_tag, changeset}}
    end
  end
end
