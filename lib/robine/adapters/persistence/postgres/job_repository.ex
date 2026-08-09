defmodule Robine.Adapters.Persistence.Postgres.JobRepository do
  @moduledoc false
  @behaviour Robine.Pipelines.Ports.JobRepository

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.Attempt, as: AttemptSchema
  alias Robine.Adapters.Persistence.Postgres.Schemas.Artifact, as: ArtifactSchema
  alias Robine.Adapters.Persistence.Postgres.Schemas.Job, as: JobSchema
  alias Robine.Adapters.Persistence.Postgres.Schemas.Pipeline, as: PipelineSchema
  alias Robine.Adapters.Persistence.Postgres.Schemas.GitHubRepository, as: SourceRepositorySchema
  alias Robine.Adapters.Persistence.Postgres.Schemas.RemoteRunner
  alias Robine.Adapters.Persistence.Postgres.Schemas.RunnerAttemptEvent
  alias Robine.Repo

  @active_attempts [:queued, :preparing, :running, :cancelling]
  @scheduler_lock_key 90_464_863_604_293

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
    started = System.monotonic_time()

    result =
      with {:ok, _result} <-
             Ecto.Adapters.SQL.query(
               Repo,
               "SELECT pg_advisory_xact_lock($1)",
               [@scheduler_lock_key]
             ) do
        active =
          Repo.aggregate(
            from(attempt in AttemptSchema, where: attempt.status in ^@active_attempts),
            :count
          )

        if active >= global_limit do
          {:error, :capacity}
        else
          find_fair_job(repository_limit, ["docker"])
        end
      else
        {:error, _reason} -> {:error, :scheduler_lock_unavailable}
      end

    :telemetry.execute(
      [:robine, :scheduler, :dispatch],
      %{duration: System.monotonic_time() - started},
      %{outcome: dispatch_outcome(result)}
    )

    result
  end

  @impl true
  def next_queued_for_runner(runner_id, now, global_limit, repository_limit) do
    started = System.monotonic_time()

    result =
      with {:ok, _result} <- scheduler_lock(),
           {:ok, labels} <- runner_capacity(runner_id, now),
           :ok <- global_capacity(global_limit) do
        find_fair_job(repository_limit, labels)
      else
        {:error, _reason} = error -> error
      end

    :telemetry.execute(
      [:robine, :scheduler, :dispatch],
      %{duration: System.monotonic_time() - started},
      %{outcome: dispatch_outcome(result)}
    )

    result
  end

  defp scheduler_lock do
    case Ecto.Adapters.SQL.query(Repo, "SELECT pg_advisory_xact_lock($1)", [@scheduler_lock_key]) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, :scheduler_lock_unavailable}
    end
  end

  defp global_capacity(global_limit) do
    active =
      Repo.aggregate(
        from(attempt in AttemptSchema, where: attempt.status in ^@active_attempts),
        :count
      )

    if active < global_limit, do: :ok, else: {:error, :capacity}
  end

  defp runner_capacity(runner_id, now) do
    stale_before = DateTime.add(now, -60, :second)
    runner = Repo.get(RemoteRunner, runner_id)

    if runner && runner.admin_state == :enabled && runner.protocol_version == 1 &&
         runner.last_seen_at && DateTime.compare(runner.last_seen_at, stale_before) != :lt &&
         runner.capabilities["docker"] == true do
      concurrency = normalize_concurrency(runner.capabilities["concurrency"])

      active =
        Repo.aggregate(
          from(attempt in AttemptSchema,
            where: attempt.runner_id == ^runner_id and attempt.status in ^@active_attempts
          ),
          :count
        )

      if active < concurrency,
        do: {:ok, effective_labels(runner)},
        else: {:error, :runner_unavailable}
    else
      {:error, :runner_unavailable}
    end
  end

  defp normalize_concurrency(value) when is_integer(value) and value in 1..64, do: value
  defp normalize_concurrency(_value), do: 1

  defp effective_labels(runner) do
    system =
      [
        if(runner.capabilities["docker"] == true, do: "docker"),
        runner.capabilities["os"],
        runner.capabilities["architecture"]
      ]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    Enum.uniq(runner.labels ++ system)
  end

  defp find_fair_job(repository_limit, labels) do
    active_by_repository =
      from attempt in AttemptSchema,
        join: active_job in JobSchema,
        on: active_job.id == attempt.job_id,
        join: pipeline in PipelineSchema,
        on: pipeline.id == active_job.pipeline_id,
        where: attempt.status in ^@active_attempts,
        group_by: pipeline.repository_id,
        select: %{repository_id: pipeline.repository_id, active_count: count(attempt.id)}

    candidates =
      Repo.all(
        from job in JobSchema,
          join: pipeline in PipelineSchema,
          on: pipeline.id == job.pipeline_id,
          left_join: source_repository in SourceRepositorySchema,
          on: source_repository.id == pipeline.repository_id,
          left_join: active in subquery(active_by_repository),
          on: active.repository_id == pipeline.repository_id,
          where:
            job.status == :queued and pipeline.status in [:queued, :running] and
              (is_nil(source_repository.id) or source_repository.trusted == true) and
              coalesce(active.active_count, 0) < ^repository_limit and
              fragment(
                "to_jsonb(?::text[]) @> COALESCE(?->'runs_on', '[\"docker\"]'::jsonb)",
                ^labels,
                job.execution_spec
              ),
          order_by: [asc: pipeline.inserted_at, asc: job.position],
          limit: 100,
          lock: "FOR UPDATE OF p0 SKIP LOCKED",
          select: job
      )

    case candidates do
      [job | _rest] -> {:ok, to_domain(job)}
      [] -> {:error, :none}
    end
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
        result = persist_attributes(schema, JobSchema, attributes, :job_persistence)
        emit_transition(:job, schema.status, job.status, result)
        emit_condition_evaluation(schema.status, job, result)

        if schema.status in [:succeeded, :failed, :cancelled, :skipped] and
             job.status in [:queued, :blocked] do
          :telemetry.execute(
            [:robine, :pipeline, :retry],
            %{count: 1},
            %{outcome: if(result == :ok, do: :queued, else: :error)}
          )
        end

        result
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
  def get_attempt(id) when is_binary(id) do
    case Repo.get(AttemptSchema, id) do
      nil -> {:error, :not_found}
      schema -> {:ok, attempt_to_domain(schema)}
    end
  end

  @impl true
  def get_attempt_by_token_for_update(token) when is_binary(token) do
    case Repo.one(
           from attempt in AttemptSchema,
             where: attempt.idempotency_token == ^token,
             lock: "FOR UPDATE"
         ) do
      nil -> {:error, :not_found}
      schema -> {:ok, attempt_to_domain(schema)}
    end
  end

  @impl true
  def get_runner_event(runner_id, message_id) do
    case Repo.one(
           from event in RunnerAttemptEvent,
             where: event.runner_id == ^runner_id and event.message_id == ^message_id
         ) do
      nil ->
        {:error, :not_found}

      event ->
        {:ok,
         %{
           runner_id: event.runner_id,
           message_id: event.message_id,
           attempt_id: event.attempt_id,
           sequence: event.sequence,
           status: event.status,
           reason: event.reason
         }}
    end
  end

  @impl true
  def insert_runner_event(attributes) do
    %RunnerAttemptEvent{}
    |> RunnerAttemptEvent.changeset(attributes)
    |> Repo.insert()
    |> case do
      {:ok, _event} -> :ok
      {:error, changeset} -> {:error, {:runner_event_persistence, changeset}}
    end
  end

  @impl true
  def update_attempt(%Robine.Pipelines.Domain.Attempt{} = attempt) do
    case Repo.get(AttemptSchema, attempt.id) do
      nil ->
        {:error, :not_found}

      schema ->
        result = persist(schema, AttemptSchema, attempt, :attempt_persistence)
        emit_transition(:attempt, schema.status, attempt.status, result)
        result
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
    list_jobs(pipeline_id, false)
  end

  @impl true
  def list_jobs_for_update(pipeline_id) when is_binary(pipeline_id) do
    list_jobs(pipeline_id, true)
  end

  defp list_jobs(pipeline_id, lock?) do
    query =
      from job in JobSchema,
        where: job.pipeline_id == ^pipeline_id,
        order_by: [asc: job.position]

    query = if lock?, do: from(job in query, lock: "FOR UPDATE"), else: query
    jobs = Repo.all(query)

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

  @impl true
  def latest_attempt(job_id) do
    case Repo.one(
           from attempt in AttemptSchema,
             where: attempt.job_id == ^job_id,
             order_by: [desc: attempt.number],
             limit: 1
         ) do
      nil -> {:error, :not_found}
      attempt -> {:ok, attempt_to_domain(attempt)}
    end
  end

  @impl true
  def missing_artifact_inputs(pipeline_id, requirements, now) do
    missing =
      Enum.reject(requirements, fn %{from: from, name: name} ->
        Repo.exists?(
          from artifact in ArtifactSchema,
            join: attempt in AttemptSchema,
            on: attempt.id == artifact.attempt_id,
            join: job in JobSchema,
            on: job.id == attempt.job_id,
            where:
              job.pipeline_id == ^pipeline_id and job.job_key == ^from and
                attempt.status == :succeeded and artifact.name == ^name and
                artifact.expires_at > ^now
        )
      end)

    {:ok, missing}
  end

  @impl true
  def list_active_attempt_ids do
    {:ok,
     Repo.all(
       from attempt in AttemptSchema,
         where: attempt.status in ^@active_attempts,
         select: attempt.id
     )}
  end

  @impl true
  def list_active_attempts_for_runner(runner_id) do
    {:ok,
     Repo.all(
       from attempt in AttemptSchema,
         where: attempt.runner_id == ^runner_id and attempt.status in ^@active_attempts,
         order_by: [asc: attempt.inserted_at]
     )
     |> Enum.map(&attempt_to_domain/1)}
  end

  @impl true
  def list_active_attempts_for_runner_for_update(runner_id) do
    {:ok,
     Repo.all(
       from attempt in AttemptSchema,
         where: attempt.runner_id == ^runner_id and attempt.status in ^@active_attempts,
         order_by: [asc: attempt.inserted_at],
         lock: "FOR UPDATE"
     )
     |> Enum.map(&attempt_to_domain/1)}
  end

  @impl true
  def cancellation_requested?(idempotency_token) do
    {:ok,
     Repo.exists?(
       from attempt in AttemptSchema,
         join: job in JobSchema,
         on: job.id == attempt.job_id,
         join: pipeline in PipelineSchema,
         on: pipeline.id == job.pipeline_id,
         where:
           attempt.idempotency_token == ^idempotency_token and
             pipeline.status in [:cancelling, :cancelled]
     )}
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
      runner_id: schema.runner_id,
      status: schema.status,
      lease_expires_at: schema.lease_expires_at,
      last_sequence: schema.last_sequence,
      result_reason: schema.result_reason,
      inserted_at: schema.inserted_at,
      updated_at: schema.updated_at
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

  defp dispatch_outcome({:ok, _job}), do: :claimed
  defp dispatch_outcome({:error, :none}), do: :empty
  defp dispatch_outcome({:error, :capacity}), do: :capacity
  defp dispatch_outcome({:error, _reason}), do: :error

  defp emit_transition(_entity, status, status, _result), do: :ok

  defp emit_transition(entity, _from, _to, result) do
    :telemetry.execute(
      [:robine, :pipeline, :transition],
      %{count: 1},
      %{entity: entity, outcome: if(result == :ok, do: :ok, else: :error)}
    )
  end

  defp emit_condition_evaluation(:blocked, %{status: status} = job, :ok)
       when status in [:queued, :skipped] do
    condition =
      case Map.get(job.execution, "condition", "success") do
        "failure" -> :failure
        "always" -> :always
        _success -> :success
      end

    :telemetry.execute(
      [:robine, :condition, :evaluation],
      %{count: 1},
      %{
        scope: :job,
        condition: condition,
        outcome: if(status == :skipped, do: :skipped, else: :matched)
      }
    )
  end

  defp emit_condition_evaluation(_from, _job, _result), do: :ok
end
