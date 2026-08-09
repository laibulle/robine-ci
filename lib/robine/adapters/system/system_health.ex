defmodule Robine.Adapters.System.SystemHealth do
  @moduledoc false
  @behaviour Robine.Operations.Ports.Health
  import Ecto.Query

  alias Robine.Repo

  alias Robine.Adapters.Persistence.Postgres.Schemas.{
    OutboxEvent,
    ScheduleReconciliationState
  }

  @impl true
  def check(blob_store) do
    checks = %{
      database: database(),
      durable_queue: durable_queue(),
      outbox: outbox(),
      scheduler: scheduler(),
      docker: docker(),
      storage: storage(blob_store),
      github_app: github_app(),
      gitlab: source_control_provider(:gitlab, :gitlab_source_control),
      forgejo: source_control_provider(:forgejo, :forgejo_source_control),
      oidc: optional_configuration(:oidc_config)
    }

    ready =
      checks.database.status == :ok and checks.durable_queue.status == :ok and
        checks.storage.status == :ok

    {:ok,
     %{
       status: if(ready, do: :ready, else: :not_ready),
       checks: checks,
       checked_at: DateTime.utc_now()
     }}
  end

  defp database do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> %{status: :ok, detail: "PostgreSQL reachable"}
      {:error, _reason} -> %{status: :error, detail: "PostgreSQL unavailable"}
    end
  rescue
    _error -> %{status: :error, detail: "PostgreSQL unavailable"}
  end

  defp durable_queue do
    count =
      Repo.aggregate(
        from(job in Oban.Job, where: job.state in ["available", "scheduled", "retryable"]),
        :count
      )

    %{status: :ok, detail: "#{count} pending durable jobs", pending: count}
  rescue
    _error -> %{status: :error, detail: "Durable queue unavailable"}
  end

  defp outbox do
    pending =
      Repo.aggregate(from(event in OutboxEvent, where: is_nil(event.delivered_at)), :count)

    stale =
      Repo.aggregate(
        from(event in OutboxEvent,
          where:
            is_nil(event.delivered_at) and
              event.occurred_at < ^DateTime.add(DateTime.utc_now(), -300, :second)
        ),
        :count
      )

    worker = "Robine.Adapters.Background.OutboxDeliveryWorker"

    dead_letters =
      Repo.aggregate(
        from(job in Oban.Job,
          where: job.worker == ^worker and job.state in ["discarded", "cancelled"]
        ),
        :count
      )

    status =
      cond do
        dead_letters > 0 -> :error
        stale > 0 -> :degraded
        true -> :ok
      end

    %{
      status: status,
      detail: "#{pending} pending, #{stale} stale, #{dead_letters} dead-letter outbox events",
      pending: pending,
      stale: stale,
      dead_letters: dead_letters
    }
  rescue
    _error -> %{status: :error, detail: "Outbox state unavailable"}
  end

  defp scheduler do
    case Repo.get(ScheduleReconciliationState, "workflows") do
      nil ->
        %{
          status: :degraded,
          detail: "Scheduled workflow reconciliation has not completed yet",
          cursor: nil,
          cursor_age_seconds: nil,
          last_failure: nil
        }

      state ->
        raw_age = state.cursor && DateTime.diff(DateTime.utc_now(), state.cursor, :second)
        age = raw_age && max(raw_age, 0)
        degraded = not is_nil(state.last_failure) or is_nil(age) or age > 120 or raw_age < -60

        %{
          status: if(degraded, do: :degraded, else: :ok),
          detail: scheduler_detail(age, state.last_failure),
          cursor: state.cursor,
          cursor_age_seconds: age,
          last_failure: state.last_failure
        }
    end
  rescue
    _error ->
      %{
        status: :error,
        detail: "Scheduled workflow reconciliation state is unavailable",
        cursor: nil,
        cursor_age_seconds: nil,
        last_failure: nil
      }
  end

  defp scheduler_detail(age, nil) when is_integer(age),
    do: "Schedule cursor is #{age} seconds old"

  defp scheduler_detail(_age, nil), do: "No successful schedule reconciliation"

  defp scheduler_detail(age, failure),
    do: "Last schedule reconciliation failed (#{failure}); cursor age #{age || "unknown"} seconds"

  defp docker do
    task =
      Task.async(fn ->
        System.cmd("docker", ["version", "--format", "{{.Server.Version}}"],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, 2_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {version, 0}} -> %{status: :ok, detail: "Docker #{String.trim(version)}"}
      _ -> %{status: :degraded, detail: "Docker Engine unavailable"}
    end
  rescue
    _error -> %{status: :degraded, detail: "Docker Engine unavailable"}
  end

  defp storage(blob_store) do
    case blob_store.health() do
      {:ok, details} -> Map.put(details, :status, :ok)
      {:error, reason} -> %{status: :error, detail: storage_error(reason)}
    end
  end

  defp storage_error(:invalid_configuration), do: "Blob storage configuration is invalid"
  defp storage_error(:forbidden), do: "Blob storage access is forbidden"
  defp storage_error(:throttled), do: "Blob storage is throttling requests"
  defp storage_error(:unavailable), do: "Blob storage is unavailable"
  defp storage_error(_reason), do: "Blob storage health check failed"

  defp github_app do
    app_id = Application.get_env(:robine, :github_app_id)
    rate_limit = Robine.Adapters.SourceControl.GitHubApiMonitor.snapshot()

    with true <- is_binary(app_id) and app_id != "",
         {:ok, _private_key} <-
           Robine.Adapters.SourceControl.GitHubCredentials.fetch(:private_key),
         {:ok, _webhook_secret} <-
           Robine.Adapters.SourceControl.GitHubCredentials.fetch(:webhook_secret) do
      github_health(:ok, "Encrypted or bootstrap credentials configured", rate_limit)
    else
      _reason -> github_health(:degraded, "GitHub App credentials incomplete", rate_limit)
    end
  end

  defp github_health(status, detail, :not_observed) do
    %{status: status, detail: detail <> "; no GitHub API request observed", rate_limit: nil}
  end

  defp github_health(status, detail, rate_limit) do
    rate_detail =
      case {rate_limit.rate_limit_remaining, rate_limit.rate_limit_limit} do
        {remaining, limit} when is_integer(remaining) and is_integer(limit) ->
          "; API rate limit #{remaining}/#{limit} remaining"

        _unknown ->
          "; API rate limit headers unavailable"
      end

    api_unhealthy =
      rate_limit.outcome == :transport_error or rate_limit.status in [401, 403, 429] or
        (is_integer(rate_limit.status) and rate_limit.status >= 500)

    effective_status =
      if api_unhealthy or rate_limit.rate_limit_remaining == 0,
        do: :degraded,
        else: status

    %{
      status: effective_status,
      detail: detail <> rate_detail,
      rate_limit: rate_limit
    }
  end

  defp optional_configuration(key) do
    if Application.get_env(:robine, key),
      do: %{status: :ok, detail: "Configured"},
      else: %{status: :optional, detail: "Not configured"}
  end

  defp source_control_provider(provider, config_key) do
    case Application.get_env(:robine, config_key, []) |> Keyword.get(:base_url) do
      base_url when is_binary(base_url) and base_url != "" ->
        with {:ok, _token} <-
               Robine.Adapters.SourceControl.ProviderCredentials.fetch(provider, :token),
             {:ok, _secret} <-
               Robine.Adapters.SourceControl.ProviderCredentials.fetch(
                 provider,
                 :webhook_secret
               ) do
          %{status: :ok, detail: "Configured credentials available"}
        else
          _error -> %{status: :degraded, detail: "Configured provider credentials incomplete"}
        end

      _disabled ->
        %{status: :optional, detail: "Not configured"}
    end
  end
end
