defmodule Robine.Adapters.System.SystemHealth do
  @moduledoc false
  @behaviour Robine.Operations.Ports.Health
  import Ecto.Query

  alias Robine.Repo

  @impl true
  def check do
    checks = %{
      database: database(),
      durable_queue: durable_queue(),
      docker: docker(),
      storage: storage(),
      github_app: configured([:github_app_id, :github_app_private_key, :github_webhook_secret]),
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

  defp storage do
    root = Application.fetch_env!(:robine, :storage_root)
    probe = Path.join(root, ".health-#{Ecto.UUID.generate()}")

    try do
      with :ok <- File.mkdir_p(root), :ok <- File.write(probe, "health", [:exclusive]) do
        %{status: :ok, detail: "Local blob storage writable"}
      else
        {:error, _reason} -> %{status: :error, detail: "Local blob storage is not writable"}
      end
    after
      File.rm(probe)
    end
  rescue
    _error -> %{status: :error, detail: "Local blob storage is not writable"}
  end

  defp configured(keys) do
    if Enum.all?(keys, fn key ->
         value = Application.get_env(:robine, key)
         is_binary(value) and value != ""
       end),
       do: %{status: :ok, detail: "Configured"},
       else: %{status: :degraded, detail: "Not fully configured"}
  end

  defp optional_configuration(key) do
    if Application.get_env(:robine, key),
      do: %{status: :ok, detail: "Configured"},
      else: %{status: :optional, detail: "Not configured"}
  end
end
