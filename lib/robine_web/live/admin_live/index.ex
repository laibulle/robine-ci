defmodule RobineWeb.AdminLive.Index do
  use RobineWeb, :live_view
  alias Robine.{Identities, Operations}

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  @impl true
  def handle_event("preflight-oidc", _params, socket) do
    case Identities.oidc_configuration(%{preflight: true}, socket.assigns.execution_context) do
      {:ok, configuration} ->
        {:noreply, assign(socket, oidc: configuration)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "OIDC preflight failed: #{inspect(reason)}")}
    end
  end

  def handle_event("refresh-health", _params, socket), do: {:noreply, load_health(socket)}

  def handle_event("run-retention", _params, socket) do
    case Operations.prune_retention(%{}, socket.assigns.execution_context) do
      {:ok, result} ->
        message =
          "Retention complete: #{result.artifacts_deleted} artifacts, " <>
            "#{result.caches_deleted} caches, #{result.logs_deleted} log chunks, " <>
            "#{result.blobs_deleted} blobs."

        {:noreply, put_flash(socket, :info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Retention failed: #{inspect(reason)}")}
    end
  end

  def handle_event("change-role", %{"user_id" => user_id, "role" => role}, socket) do
    role =
      if role in ~w(administrator maintainer viewer),
        do: String.to_existing_atom(role),
        else: :invalid

    case Identities.change_user_role(
           %{user_id: user_id, role: role},
           socket.assigns.execution_context
         ) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, "Role updated.") |> load()}

      {:error, :last_administrator} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Create another usable administrator before changing the last administrator."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot update role: #{inspect(reason)}")}
    end
  end

  defp load(socket) do
    with {:ok, users} <- Identities.list_users(%{}, socket.assigns.execution_context),
         {:ok, oidc} <- Identities.oidc_configuration(%{}, socket.assigns.execution_context) do
      socket
      |> assign(users: users, oidc: oidc, retention: retention_projection())
      |> load_health()
    else
      {:error, reason} ->
        socket
        |> assign(
          users: [],
          oidc: %{enabled: false, preflight: {:error, reason}},
          retention: retention_projection()
        )
        |> load_health()
    end
  end

  defp load_health(socket) do
    case Operations.health(%{}, socket.assigns.execution_context) do
      {:ok, health} -> assign(socket, health: health)
      {:error, _reason} -> assign(socket, health: %{status: :not_ready, checks: %{}})
    end
  end

  defp check_label(:database), do: "PostgreSQL"
  defp check_label(:durable_queue), do: "Durable queue"
  defp check_label(:docker), do: "Docker Engine"
  defp check_label(:storage), do: "Blob storage"
  defp check_label(:github_app), do: "GitHub App"
  defp check_label(:oidc), do: "OpenID Connect"

  defp status_class(:ok), do: "badge-success"
  defp status_class(:optional), do: "badge-ghost"
  defp status_class(:degraded), do: "badge-warning"
  defp status_class(:error), do: "badge-error"

  defp retention_projection do
    policy = Application.fetch_env!(:robine, :retention)

    %{
      log_days: div(Keyword.fetch!(policy, :log_seconds), 86_400),
      gc_grace_minutes: div(Keyword.fetch!(policy, :gc_grace_seconds), 60),
      batch_size: Keyword.fetch!(policy, :batch_size)
    }
  end

  defp preflight_text(:not_run), do: "Not tested"
  defp preflight_text(:not_configured), do: "Not configured"
  defp preflight_text({:ok, host}), do: "Discovery succeeded via #{host}"
  defp preflight_text({:error, _reason}), do: "Discovery failed"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-10">
        <header>
          <p class="text-sm font-semibold uppercase tracking-[0.2em] text-primary">Instance</p><h1 class="mt-2 text-4xl font-bold">
            Administration
          </h1><p class="mt-2 text-base-content/60">
            Identity configuration and operator recovery status.
          </p>
        </header>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">Instance health</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Readiness is {@health.status}. Optional integrations may be degraded without stopping the control plane.
              </p>
            </div>
            <button
              phx-click="refresh-health"
              class="btn btn-outline btn-sm"
              phx-disable-with="Checking…"
            >
              Refresh
            </button>
          </div>
          <div class="mt-6 grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <article
              :for={{name, check} <- @health.checks}
              id={"health-#{name}"}
              class="rounded-2xl border border-base-300 p-4"
            >
              <div class="flex items-center justify-between gap-3">
                <h3 class="font-semibold">{check_label(name)}</h3>
                <span class={["badge badge-sm", status_class(check.status)]}>{check.status}</span>
              </div>
              <p class="mt-2 text-sm text-base-content/60">{check.detail}</p>
            </article>
          </div>
        </section>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">Retention policy</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Expired metadata is pruned transactionally; unreferenced blobs are deleted after a safety grace period.
              </p>
            </div>
            <button
              phx-click="run-retention"
              class="btn btn-outline btn-sm"
              phx-disable-with="Pruning…"
            >
              Run cleanup now
            </button>
          </div>
          <dl class="mt-6 grid gap-4 sm:grid-cols-3">
            <div>
              <dt class="text-xs uppercase tracking-wide text-base-content/50">Logs</dt><dd class="mt-1 font-semibold">
                {@retention.log_days} days
              </dd>
            </div>
            <div>
              <dt class="text-xs uppercase tracking-wide text-base-content/50">Blob grace</dt><dd class="mt-1 font-semibold">
                {@retention.gc_grace_minutes} minutes
              </dd>
            </div>
            <div>
              <dt class="text-xs uppercase tracking-wide text-base-content/50">Batch limit</dt><dd class="mt-1 font-semibold">
                {@retention.batch_size}
              </dd>
            </div>
          </dl>
        </section>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">OpenID Connect</h2><p class="mt-1 text-sm text-base-content/60">
                {if @oidc.enabled,
                  do: @oidc.issuer,
                  else: "Optional SSO is disabled; local recovery remains available."}
              </p>
            </div><button
              :if={@oidc.enabled}
              phx-click="preflight-oidc"
              class="btn btn-outline btn-sm"
              phx-disable-with="Testing discovery…"
            >Test provider</button>
          </div><dl :if={@oidc.enabled} class="mt-6 grid gap-4 md:grid-cols-2">
            <div>
              <dt class="text-xs uppercase tracking-wide text-base-content/50">Exact redirect URI</dt><dd class="mt-1 break-all font-mono text-sm">
                {@oidc.redirect_uri}
              </dd>
            </div><div>
              <dt class="text-xs uppercase tracking-wide text-base-content/50">Preflight</dt><dd class="mt-1 text-sm">
                {preflight_text(@oidc.preflight)}
              </dd>
            </div>
          </dl>
        </section>
        <section>
          <h2 class="text-xl font-semibold">Users and roles</h2><div class="mt-4 overflow-x-auto rounded-3xl border border-base-300 bg-base-100">
            <table class="table">
              <thead>
                <tr>
                  <th>User</th><th>Status</th><th>Role</th>
                </tr>
              </thead><tbody>
                <tr :for={user <- @users} id={"user-#{user.id}"}>
                  <td>
                    <span class="font-semibold">{user.email}</span><span
                      :if={user.id == @current_actor.id}
                      class="ml-2 badge badge-ghost"
                    >You</span>
                  </td><td>{if user.disabled, do: "Disabled", else: "Active"}</td><td>
                    <form
                      id={"role-#{user.id}"}
                      phx-change="change-role"
                      data-confirm="Change this user's instance role?"
                    >
                      <input type="hidden" name="user_id" value={user.id} /><select
                        name="role"
                        class="select select-bordered select-sm"
                        aria-label={"Role for #{user.email}"}
                      ><option
                        :for={role <- [:administrator, :maintainer, :viewer]}
                        value={role}
                        selected={role == user.role}
                      >
                        {role}
                      </option></select>
                    </form>
                  </td>
                </tr>
              </tbody>
            </table>
          </div><p class="mt-3 text-sm text-base-content/60">
            Robine refuses to demote the last usable administrator.
          </p>
        </section>
      </section>
    </Layouts.app>
    """
  end
end
