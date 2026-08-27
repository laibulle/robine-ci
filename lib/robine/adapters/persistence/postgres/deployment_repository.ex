defmodule Robine.Adapters.Persistence.Postgres.DeploymentRepository do
  @moduledoc false
  @behaviour Robine.Deployments.Ports.Repository

  import Ecto.Query

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    AuditEvent,
    Deployment,
    DeploymentEnvironment,
    DeploymentEvent
  }

  alias Robine.Deployments.Domain.ArtifactSnapshot
  alias Robine.Deployments.Domain.Deployment, as: DomainDeployment
  alias Robine.Deployments.Domain.Environment
  alias Robine.Repo

  @impl true
  def get_environment(environment_id) when is_binary(environment_id) do
    case Repo.get(DeploymentEnvironment, environment_id) do
      nil -> {:error, :not_found}
      schema -> domain_environment(schema)
    end
  end

  def get_environment(_environment_id), do: {:error, :not_found}

  @impl true
  def get_environment_by_name(repository_id, name)
      when is_binary(repository_id) and is_binary(name) do
    case Repo.get_by(DeploymentEnvironment, repository_id: repository_id, name: name) do
      nil -> {:error, :not_found}
      schema -> domain_environment(schema)
    end
  end

  def get_environment_by_name(_repository_id, _name), do: {:error, :not_found}

  @impl true
  def list_environments(repository_id) when is_binary(repository_id) do
    DeploymentEnvironment
    |> where([environment], environment.repository_id == ^repository_id)
    |> order_by([environment], asc: environment.name)
    |> Repo.all()
    |> map_domains(&domain_environment/1)
  end

  def list_environments(_repository_id), do: {:error, :invalid_repository_id}

  @impl true
  def upsert_environment(%Environment{} = environment, audit) do
    Repo.transaction(fn ->
      attributes = serialize_environment(environment)

      result =
        case Repo.get(DeploymentEnvironment, environment.id) do
          nil ->
            DeploymentEnvironment.changeset(%DeploymentEnvironment{}, attributes) |> Repo.insert()

          schema ->
            DeploymentEnvironment.changeset(schema, attributes) |> Repo.update()
        end

      with {:ok, _schema} <- result,
           {:ok, _event} <-
             audit_event(
               audit,
               "deployment.environment_configured",
               "deployment_environment",
               environment.id,
               environment.updated_at,
               %{repository_id: environment.repository_id, name: environment.name}
             ) do
        :ok
      else
        {:error, changeset} -> Repo.rollback({:deployment_persistence, changeset})
      end
    end)
    |> unwrap()
  end

  @impl true
  def insert_deployment(%DomainDeployment{} = deployment, audit) do
    Repo.transaction(fn ->
      with {:ok, _schema} <-
             Deployment.changeset(%Deployment{}, serialize_deployment(deployment))
             |> Repo.insert(),
           {:ok, _event} <-
             audit_event(
               audit,
               "deployment.requested",
               "deployment",
               deployment.id,
               deployment.requested_at,
               %{
                 environment_id: deployment.environment_id,
                 artifact_digest: deployment.artifact.digest,
                 kind: deployment.kind
               }
             ) do
        :ok
      else
        {:error, changeset} -> Repo.rollback({:deployment_persistence, changeset})
      end
    end)
    |> unwrap()
    |> normalize_active_conflict()
  end

  @impl true
  def get_deployment(deployment_id) when is_binary(deployment_id) do
    case Repo.get(Deployment, deployment_id) do
      nil -> {:error, :not_found}
      schema -> domain_deployment(schema)
    end
  end

  def get_deployment(_deployment_id), do: {:error, :not_found}

  @impl true
  def find_equivalent_deployment(environment_id, digest, kind)
      when is_binary(environment_id) and is_binary(digest) and is_atom(kind) do
    active_or_successful = [
      :requested,
      :awaiting_approval,
      :queued,
      :preparing,
      :converging_services,
      :migrating,
      :activating,
      :verifying,
      :succeeded
    ]

    query =
      from deployment in Deployment,
        where:
          deployment.environment_id == ^environment_id and deployment.kind == ^kind and
            fragment("?->>'digest'", deployment.artifact) == ^digest and
            deployment.status in ^active_or_successful,
        order_by: [desc: deployment.requested_at],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> domain_deployment(schema)
    end
  end

  def find_equivalent_deployment(_environment_id, _digest, _kind), do: {:error, :not_found}

  @impl true
  def update_deployment(%DomainDeployment{} = deployment, expected_status, audit) do
    Repo.transaction(fn ->
      schema = locked_deployment(deployment.id)

      cond do
        is_nil(schema) ->
          Repo.rollback(:not_found)

        schema.status != expected_status ->
          Repo.rollback(:stale_deployment)

        true ->
          with {:ok, _updated} <-
                 Deployment.changeset(schema, serialize_deployment(deployment)) |> Repo.update(),
               {:ok, _event} <-
                 audit_event(
                   audit,
                   Map.get(audit, :action, "deployment.updated"),
                   "deployment",
                   deployment.id,
                   deployment.updated_at,
                   %{from: expected_status, to: deployment.status}
                 ) do
            :ok
          else
            {:error, changeset} -> Repo.rollback({:deployment_persistence, changeset})
          end
      end
    end)
    |> unwrap()
    |> normalize_active_conflict()
  end

  @impl true
  def record_event(%DomainDeployment{} = deployment, expected_status, reason, occurred_at, audit) do
    Repo.transaction(fn ->
      schema = locked_deployment(deployment.id)

      cond do
        is_nil(schema) ->
          Repo.rollback(:not_found)

        schema.status != expected_status or schema.event_sequence + 1 != deployment.event_sequence ->
          Repo.rollback(:stale_deployment)

        true ->
          event_attributes = %{
            id: Ecto.UUID.generate(),
            deployment_id: deployment.id,
            message_id: Map.fetch!(audit, :message_id),
            sequence: deployment.event_sequence,
            from_status: Atom.to_string(expected_status),
            to_status: Atom.to_string(deployment.status),
            reason: reason,
            runner_id: Map.get(audit, :runner_id),
            occurred_at: occurred_at
          }

          with {:ok, _event} <-
                 DeploymentEvent.changeset(%DeploymentEvent{}, event_attributes) |> Repo.insert(),
               {:ok, _updated} <-
                 Deployment.changeset(schema, serialize_deployment(deployment)) |> Repo.update(),
               {:ok, _audit_event} <-
                 audit_event(
                   Map.put(
                     audit,
                     :actor_id,
                     Map.get(audit, :actor_id) || Map.fetch!(audit, :runner_id)
                   ),
                   "deployment.phase_changed",
                   "deployment",
                   deployment.id,
                   occurred_at,
                   %{
                     sequence: deployment.event_sequence,
                     from: expected_status,
                     to: deployment.status
                   }
                 ) do
            :ok
          else
            {:error, changeset} -> Repo.rollback({:deployment_persistence, changeset})
          end
      end
    end)
    |> unwrap()
  end

  @impl true
  def find_event(deployment_id, message_id)
      when is_binary(deployment_id) and is_binary(message_id) do
    query =
      from event in DeploymentEvent,
        where: event.deployment_id == ^deployment_id and event.message_id == ^message_id,
        select: %{
          deployment_id: event.deployment_id,
          message_id: event.message_id,
          sequence: event.sequence,
          status: event.to_status,
          reason: event.reason
        }

    case Repo.one(query) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  @impl true
  def list_deployments(repository_id) when is_binary(repository_id) do
    Deployment
    |> where([deployment], deployment.repository_id == ^repository_id)
    |> order_by([deployment], desc: deployment.requested_at)
    |> limit(100)
    |> Repo.all()
    |> map_domains(&domain_deployment/1)
  end

  def list_deployments(_repository_id), do: {:error, :invalid_repository_id}

  @impl true
  def next_queued do
    busy_environments =
      from deployment in Deployment,
        where:
          not is_nil(deployment.runner_id) or
            deployment.status in [
              :preparing,
              :converging_services,
              :migrating,
              :activating,
              :verifying
            ],
        select: deployment.environment_id

    query =
      from deployment in Deployment,
        where:
          deployment.status == :queued and is_nil(deployment.runner_id) and
            deployment.environment_id not in subquery(busy_environments),
        order_by: [asc: deployment.requested_at, asc: deployment.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :none}
      schema -> domain_deployment(schema)
    end
  end

  @impl true
  def get_runner_deployment(deployment_id, runner_id)
      when is_binary(deployment_id) and is_binary(runner_id) do
    query =
      from deployment in Deployment,
        where:
          deployment.id == ^deployment_id and deployment.runner_id == ^runner_id and
            not is_nil(deployment.runner_id)

    case Repo.one(query) do
      nil -> {:error, :not_found}
      schema -> domain_deployment(schema)
    end
  end

  def get_runner_deployment(_deployment_id, _runner_id), do: {:error, :not_found}

  defp locked_deployment(id) do
    Repo.one(from deployment in Deployment, where: deployment.id == ^id, lock: "FOR UPDATE")
  end

  defp serialize_environment(environment) do
    environment
    |> Map.from_struct()
    |> Map.update!(:services, fn services -> Enum.map(services, &Map.from_struct/1) end)
  end

  defp serialize_deployment(deployment) do
    deployment
    |> Map.from_struct()
    |> Map.update!(:artifact, &Map.from_struct/1)
    |> Map.update!(:environment_snapshot, fn snapshot ->
      Map.update!(snapshot, :services, fn services -> Enum.map(services, &service_map/1) end)
    end)
  end

  defp service_map(%_{} = service), do: Map.from_struct(service)
  defp service_map(service) when is_map(service), do: service

  defp domain_environment(schema) do
    Environment.new(%{
      id: schema.id,
      repository_id: schema.repository_id,
      name: schema.name,
      protection: schema.protection,
      runner_labels: schema.runner_labels,
      deployment_root: schema.deployment_root,
      network_name: schema.network_name,
      timeout_ms: schema.timeout_ms,
      migration_policy: schema.migration_policy,
      verification: atomize_known(schema.verification),
      services: Enum.map(schema.services, &atomize_known/1),
      inserted_at: schema.inserted_at,
      updated_at: schema.updated_at
    })
  end

  defp domain_deployment(schema) do
    with {:ok, artifact} <- ArtifactSnapshot.new(atomize_known(schema.artifact)) do
      {:ok,
       struct!(DomainDeployment, %{
         id: schema.id,
         environment_id: schema.environment_id,
         repository_id: schema.repository_id,
         requester_id: schema.requester_id,
         approver_id: schema.approver_id,
         attempt_id: schema.attempt_id,
         idempotency_token: schema.idempotency_token,
         runner_id: schema.runner_id,
         kind: schema.kind,
         status: schema.status,
         artifact: artifact,
         desired_state_digest: schema.desired_state_digest,
         environment_snapshot: atomize_known(schema.environment_snapshot),
         migration_policy: schema.migration_policy,
         event_sequence: schema.event_sequence,
         failure_reason: schema.failure_reason,
         requested_at: schema.requested_at,
         approved_at: schema.approved_at,
         assigned_at: schema.assigned_at,
         lease_expires_at: schema.lease_expires_at,
         started_at: schema.started_at,
         finished_at: schema.finished_at,
         updated_at: schema.updated_at
       })}
    end
  end

  defp atomize_known(value) when is_list(value), do: Enum.map(value, &atomize_known/1)

  defp atomize_known(value) when is_map(value) do
    known = %{
      "artifact_id" => :artifact_id,
      "pipeline_id" => :pipeline_id,
      "filename" => :filename,
      "digest" => :digest,
      "size" => :size,
      "tag" => :tag,
      "commit_sha" => :commit_sha,
      "id" => :id,
      "repository_id" => :repository_id,
      "protection" => :protection,
      "runner_labels" => :runner_labels,
      "deployment_root" => :deployment_root,
      "network_name" => :network_name,
      "migration_policy" => :migration_policy,
      "verification" => :verification,
      "services" => :services,
      "desired_state_digest" => :desired_state_digest,
      "inserted_at" => :inserted_at,
      "updated_at" => :updated_at,
      "role" => :role,
      "name" => :name,
      "image" => :image,
      "command" => :command,
      "environment" => :environment,
      "secret_environment" => :secret_environment,
      "volumes" => :volumes,
      "healthcheck" => :healthcheck,
      "spec_digest" => :spec_digest,
      "mount_path" => :mount_path,
      "read_only" => :read_only,
      "type" => :type,
      "url" => :url,
      "port" => :port,
      "timeout_ms" => :timeout_ms,
      "expected_status" => :expected_status,
      "version_path" => :version_path,
      "first" => :first,
      "last" => :last
    }

    Map.new(value, fn {key, item} -> {Map.get(known, key, key), atomize_known(item)} end)
  end

  defp atomize_known(value), do: value

  defp map_domains(schemas, mapper) do
    Enum.reduce_while(schemas, {:ok, []}, fn schema, {:ok, domains} ->
      case mapper.(schema) do
        {:ok, domain} -> {:cont, {:ok, [domain | domains]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, domains} -> {:ok, Enum.reverse(domains)}
      error -> error
    end
  end

  defp audit_event(audit, action, target_type, target_id, occurred_at, metadata) do
    AuditEvent.changeset(%AuditEvent{}, %{
      actor_id: Map.fetch!(audit, :actor_id),
      action: action,
      target_type: target_type,
      target_id: target_id,
      occurred_at: occurred_at,
      metadata: Map.put(metadata, :correlation_id, Map.get(audit, :correlation_id))
    })
    |> Repo.insert()
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: {:error, reason}

  defp normalize_active_conflict({:error, {:deployment_persistence, changeset}} = error) do
    cond do
      "has already been taken" in errors_on(changeset, :environment_id) ->
        {:error, :deployment_already_active}

      "has already been taken" in errors_on(changeset, :runner_id) ->
        {:error, :runner_already_active}

      true ->
        error
    end
  end

  defp normalize_active_conflict(result), do: result

  defp errors_on(changeset, field) do
    changeset.errors
    |> Keyword.get_values(field)
    |> Enum.map(fn {message, _options} -> message end)
  end
end
