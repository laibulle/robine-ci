defmodule RobineWeb.AdminLive.Index do
  use RobineWeb, :live_view
  alias Robine.{Autoscaling, Identities, Operations, Runners, Secrets}

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

  def handle_event("create-runner-enrollment", _params, socket) do
    case Runners.create_enrollment_token(%{}, socket.assigns.execution_context) do
      {:ok, enrollment} ->
        {:noreply, assign(socket, runner_enrollment: enrollment)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Cannot create runner enrollment: #{inspect(reason)}")}
    end
  end

  def handle_event("update-runner", %{"runner" => params}, socket) do
    labels =
      params
      |> Map.get("labels", "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    case Runners.update_runner(
           %{runner_id: params["runner_id"], name: params["name"], labels: labels},
           socket.assigns.execution_context
         ) do
      {:ok, _runner} ->
        {:noreply, socket |> put_flash(:info, "Runner updated.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot update runner: #{inspect(reason)}")}
    end
  end

  def handle_event("set-runner-state", %{"runner_id" => runner_id, "state" => state}, socket) do
    admin_state = if state == "enabled", do: :enabled, else: :draining

    case Runners.update_runner(
           %{runner_id: runner_id, admin_state: admin_state},
           socket.assigns.execution_context
         ) do
      {:ok, _runner} ->
        {:noreply, socket |> put_flash(:info, "Runner state updated.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot change runner state: #{inspect(reason)}")}
    end
  end

  def handle_event("rotate-runner", %{"runner_id" => runner_id}, socket) do
    case Runners.rotate_credential(%{runner_id: runner_id}, socket.assigns.execution_context) do
      {:ok, credential} ->
        {:noreply,
         socket
         |> assign(runner_credential: credential)
         |> put_flash(:info, "Credential rotated. Copy the replacement now.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot rotate credential: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke-runner", %{"runner_id" => runner_id}, socket) do
    case Runners.revoke(%{runner_id: runner_id}, socket.assigns.execution_context) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Runner revoked.") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot revoke runner: #{inspect(reason)}")}
    end
  end

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

  def handle_event("rotate-secret-keys", _params, socket) do
    input =
      case socket.assigns.secret_rotation_cursor do
        nil -> %{limit: 100}
        cursor -> %{limit: 100, cursor: cursor}
      end

    case Secrets.rotate_keys(input, socket.assigns.execution_context) do
      {:ok, result} ->
        message =
          if result.complete,
            do: "Secret key rotation complete; #{result.rotated} secrets rotated in this batch.",
            else: "Rotated #{result.rotated} secrets; continue to process the next batch."

        {:noreply,
         socket
         |> assign(secret_rotation_cursor: result.next_cursor)
         |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Secret key rotation failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save-github-private-key", %{"value" => value}, socket) do
    store_source_control_credential(socket, "GITHUB_APP_PRIVATE_KEY", value, "GitHub private key")
  end

  def handle_event("save-github-webhook-secret", %{"value" => value}, socket) do
    store_source_control_credential(socket, "GITHUB_WEBHOOK_SECRET", value, "Webhook secret")
  end

  def handle_event("save-gitlab-token", %{"value" => value}, socket) do
    store_source_control_credential(socket, "GITLAB_TOKEN", value, "GitLab API token")
  end

  def handle_event("save-gitlab-webhook-secret", %{"value" => value}, socket) do
    store_source_control_credential(
      socket,
      "GITLAB_WEBHOOK_SECRET",
      value,
      "GitLab webhook secret"
    )
  end

  def handle_event("save-forgejo-token", %{"value" => value}, socket) do
    store_source_control_credential(socket, "FORGEJO_TOKEN", value, "Forgejo API token")
  end

  def handle_event("save-forgejo-webhook-secret", %{"value" => value}, socket) do
    store_source_control_credential(
      socket,
      "FORGEJO_WEBHOOK_SECRET",
      value,
      "Forgejo webhook secret"
    )
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
         {:ok, oidc} <- Identities.oidc_configuration(%{}, socket.assigns.execution_context),
         {:ok, runners} <- Runners.list_fleet(%{}, socket.assigns.execution_context),
         {:ok, autoscaling} <- Autoscaling.fleet_capacity(%{}, socket.assigns.execution_context) do
      socket
      |> assign(
        users: users,
        oidc: oidc,
        runner_forms: runner_forms(runners),
        retention: retention_projection(),
        runner_enrollment: Map.get(socket.assigns, :runner_enrollment),
        runner_credential: Map.get(socket.assigns, :runner_credential),
        secret_rotation_cursor: Map.get(socket.assigns, :secret_rotation_cursor)
      )
      |> stream(:runners, runners, reset: true)
      |> stream(:autoscaling_policies, autoscaling, reset: true)
      |> load_health()
    else
      {:error, reason} ->
        socket
        |> assign(
          users: [],
          oidc: %{enabled: false, preflight: {:error, reason}},
          runner_forms: %{},
          retention: retention_projection(),
          runner_enrollment: Map.get(socket.assigns, :runner_enrollment),
          runner_credential: Map.get(socket.assigns, :runner_credential),
          secret_rotation_cursor: Map.get(socket.assigns, :secret_rotation_cursor)
        )
        |> stream(:runners, [], reset: true)
        |> stream(:autoscaling_policies, [], reset: true)
        |> load_health()
    end
  end

  defp load_health(socket) do
    case Operations.health(%{}, socket.assigns.execution_context) do
      {:ok, health} -> assign(socket, health: health)
      {:error, _reason} -> assign(socket, health: %{status: :not_ready, checks: %{}})
    end
  end

  defp store_source_control_credential(socket, name, value, label) do
    case Secrets.store_secret(
           %{
             name: name,
             value: value,
             scope: :instance,
             allowed_repository_ids: []
           },
           socket.assigns.execution_context
         ) do
      {:ok, _metadata} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{label} encrypted and stored. The value cannot be displayed again."
         )
         |> load_health()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot store #{label}: #{inspect(reason)}")}
    end
  end

  defp check_label(:database), do: "PostgreSQL"
  defp check_label(:durable_queue), do: "Durable queue"
  defp check_label(:outbox), do: "Event outbox"
  defp check_label(:scheduler), do: "Scheduled workflows"
  defp check_label(:docker), do: "Docker Engine"
  defp check_label(:storage), do: "Blob storage"
  defp check_label(:github_app), do: "GitHub App"
  defp check_label(:gitlab), do: "GitLab"
  defp check_label(:forgejo), do: "Forgejo"
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

  defp runner_forms(runners) do
    Map.new(runners, fn runner ->
      form =
        to_form(
          %{
            "runner_id" => runner.id,
            "name" => runner.name,
            "labels" => Enum.join(runner.labels, ", ")
          },
          as: :runner
        )

      {runner.id, form}
    end)
  end

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
          <div>
            <p class="text-sm font-semibold uppercase tracking-[0.16em] text-primary">
              Elastic capacity
            </p>
            <h2 class="mt-1 text-xl font-semibold">Autoscaling</h2>
            <p class="mt-1 max-w-3xl text-sm text-base-content/60">
              No infrastructure provider is enabled by default. Every provider effect is backed by a durable idempotent intent.
            </p>
          </div>
          <div id="autoscaling-policies" phx-update="stream" class="mt-5 grid gap-3">
            <p
              id="autoscaling-empty"
              class="hidden rounded-2xl border border-dashed border-base-300 p-5 text-sm text-base-content/60 only:block"
            >
              Static runners only. Configure a provider adapter and policy to enable elastic capacity.
            </p>
            <article
              :for={{dom_id, policy} <- @streams.autoscaling_policies}
              id={dom_id}
              class="flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-base-300 p-4"
            >
              <div>
                <h3 class="font-semibold">{policy.name}</h3>
                <p class="mt-1 text-xs text-base-content/55">
                  {policy.provider} · {policy.queued_demand || 0} queued jobs
                </p>
              </div>
              <div class="flex items-center gap-3">
                <span class="badge badge-outline">desired {policy.desired || "—"}</span>
                <span class="badge badge-outline">observed {policy.observed || "—"}</span>
                <span class={
                  if policy.health == :healthy, do: "badge badge-success", else: "badge badge-warning"
                }>{policy.health}</span>
              </div>
            </article>
          </div>
        </section>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div>
            <p class="text-sm font-semibold uppercase tracking-[0.16em] text-primary">Fleet</p>
            <h2 class="mt-1 text-xl font-semibold">Remote runners</h2>
            <p class="mt-1 max-w-3xl text-sm text-base-content/60">
              Operator labels are separate from machine-reported capabilities. Draining preserves active work and prevents new assignments.
            </p>
          </div>
          <div
            :if={@runner_credential}
            id="runner-credential-result"
            role="status"
            class="mt-5 rounded-2xl border border-warning/40 bg-warning/10 p-4"
          >
            <p class="font-semibold">Copy the replacement credential now</p>
            <code class="mt-2 block break-all rounded-xl bg-base-300 p-3 text-xs">{@runner_credential.credential}</code>
          </div>
          <div id="runner-fleet" phx-update="stream" class="mt-6 grid gap-4">
            <p
              id="runner-fleet-empty"
              class="hidden rounded-2xl border border-dashed border-base-300 p-6 text-sm text-base-content/60 only:block"
            >
              No remote runner is enrolled yet.
            </p>
            <article
              :for={{dom_id, runner} <- @streams.runners}
              id={dom_id}
              class="rounded-2xl border border-base-300 p-5 transition hover:border-primary/40"
            >
              <div class="flex flex-wrap items-start justify-between gap-4">
                <div>
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="font-semibold">{runner.name}</h3>
                    <span class="badge badge-outline">{runner.admin_state}</span>
                    <span class="badge badge-ghost">{runner.connectivity}</span>
                  </div>
                  <p class="mt-2 text-xs text-base-content/55">
                    {runner.software_version || "version unknown"} · {runner.active_attempts}/{runner.concurrency} slots active · last heartbeat {if runner.last_seen_at,
                      do: DateTime.to_iso8601(runner.last_seen_at),
                      else: "never"}
                  </p>
                  <div class="mt-3 flex flex-wrap gap-2">
                    <span :for={label <- runner.labels} class="badge badge-primary badge-outline">{label}</span>
                    <span :for={{key, value} <- runner.capabilities} class="badge badge-ghost">{key}: {to_string(
                      value
                    )}</span>
                  </div>
                </div>
                <div :if={runner.admin_state != :revoked} class="flex flex-wrap gap-2">
                  <button
                    id={"runner-state-#{runner.id}"}
                    phx-click="set-runner-state"
                    phx-value-runner_id={runner.id}
                    phx-value-state={
                      if runner.admin_state == :draining, do: "enabled", else: "draining"
                    }
                    class="btn btn-outline btn-sm"
                  >
                    {if runner.admin_state == :draining, do: "Enable", else: "Drain"}
                  </button>
                  <button
                    id={"rotate-runner-#{runner.id}"}
                    phx-click="rotate-runner"
                    phx-value-runner_id={runner.id}
                    data-confirm="Rotate this credential? The previous credential remains valid for five minutes."
                    class="btn btn-outline btn-sm"
                  >
                    Rotate credential
                  </button>
                  <button
                    id={"revoke-runner-#{runner.id}"}
                    phx-click="revoke-runner"
                    phx-value-runner_id={runner.id}
                    data-confirm="Revoke this runner immediately? It will be disconnected and cannot authenticate again."
                    class="btn btn-error btn-outline btn-sm"
                  >
                    Revoke
                  </button>
                </div>
              </div>
              <.form
                :if={runner.admin_state != :revoked}
                for={@runner_forms[runner.id]}
                id={"runner-form-#{runner.id}"}
                phx-submit="update-runner"
                class="mt-5 grid gap-3 md:grid-cols-[1fr_2fr_auto] md:items-end"
              >
                <.input field={@runner_forms[runner.id][:runner_id]} type="hidden" />
                <.input field={@runner_forms[runner.id][:name]} label="Display name" required />
                <.input
                  field={@runner_forms[runner.id][:labels]}
                  label="Operator labels (comma-separated)"
                />
                <button class="btn btn-primary" phx-disable-with="Saving…">Save</button>
              </.form>
            </article>
          </div>
        </section>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <h2 class="text-xl font-semibold">GitLab and Forgejo credentials</h2>
          <p class="mt-1 max-w-3xl text-sm text-base-content/60">
            Configure provider origins with <code>GITLAB_URL</code>
            and <code>FORGEJO_URL</code>. Values stored below are encrypted, write-only, and override environment bootstrap credentials.
          </p>
          <div class="mt-6 grid gap-6 md:grid-cols-2">
            <form
              :for={
                {id, event, label} <- [
                  {"gitlab-token", "save-gitlab-token", "GitLab API token"},
                  {"gitlab-webhook-secret", "save-gitlab-webhook-secret", "GitLab webhook secret"},
                  {"forgejo-token", "save-forgejo-token", "Forgejo API token"},
                  {"forgejo-webhook-secret", "save-forgejo-webhook-secret", "Forgejo webhook secret"}
                ]
              }
              id={id <> "-form"}
              phx-submit={event}
              class="space-y-3"
            >
              <label for={id} class="font-semibold">{label}</label>
              <input
                id={id}
                type="password"
                name="value"
                required
                minlength="8"
                maxlength="65536"
                autocomplete="new-password"
                class="input input-bordered w-full"
              />
              <button class="btn btn-primary btn-sm" phx-disable-with="Encrypting…">
                Store {label}
              </button>
            </form>
          </div>
        </section>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">Remote runner enrollment</h2>
              <p class="mt-1 max-w-3xl text-sm text-base-content/60">
                Generate a single-use token valid for 15 minutes. It is displayed once and grants creation of one machine identity.
              </p>
            </div>
            <button
              id="create-runner-enrollment"
              phx-click="create-runner-enrollment"
              class="btn btn-primary btn-sm"
              phx-disable-with="Generating…"
            >
              Generate enrollment command
            </button>
          </div>
          <div
            :if={@runner_enrollment}
            id="runner-enrollment-result"
            role="status"
            class="mt-6 rounded-2xl border border-warning/40 bg-warning/10 p-4"
          >
            <p class="font-semibold">Copy this command now</p>
            <p class="mt-1 text-sm text-base-content/70">
              Replace <code>RUNNER_NAME</code>
              and run it on the trusted worker. The token expires at {DateTime.to_iso8601(
                @runner_enrollment.expires_at
              )}.
            </p>
            <pre class="mt-3 overflow-x-auto whitespace-pre-wrap break-all rounded-xl bg-base-300 p-3 text-xs"><code>ROBINE_RUNNER_ENROLLMENT_TOKEN='{@runner_enrollment.token}' robine-runner enroll --server '{Application.fetch_env!(:robine, :public_url)}' --name 'RUNNER_NAME' --config /etc/robine-runner/config.json</code></pre>
          </div>
        </section>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <h2 class="text-xl font-semibold">GitHub App credentials</h2>
          <p class="mt-1 max-w-3xl text-sm text-base-content/60">
            Values are encrypted with the instance secret key, are never displayed again, and override environment bootstrap credentials. Configure the non-secret App ID with <code>GITHUB_APP_ID</code>.
          </p>
          <div class="mt-6 grid gap-6 lg:grid-cols-2">
            <form id="github-private-key-form" phx-submit="save-github-private-key" class="space-y-3">
              <label for="github-private-key" class="font-semibold">Private key (PEM)</label>
              <textarea
                id="github-private-key"
                name="value"
                required
                minlength="8"
                maxlength="65536"
                autocomplete="off"
                spellcheck="false"
                class="textarea textarea-bordered min-h-32 w-full font-mono text-xs"
              ></textarea>
              <button class="btn btn-primary btn-sm" phx-disable-with="Encrypting…">
                Store private key
              </button>
            </form>
            <form
              id="github-webhook-secret-form"
              phx-submit="save-github-webhook-secret"
              class="space-y-3"
            >
              <label for="github-webhook-secret" class="font-semibold">Webhook secret</label>
              <input
                id="github-webhook-secret"
                type="password"
                name="value"
                required
                minlength="8"
                maxlength="65536"
                autocomplete="new-password"
                class="input input-bordered w-full"
              />
              <button class="btn btn-primary btn-sm" phx-disable-with="Encrypting…">
                Store webhook secret
              </button>
            </form>
          </div>
        </section>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">Secret encryption keys</h2>
              <p class="mt-1 max-w-2xl text-sm text-base-content/60">
                Re-encrypt stored secrets in bounded audited batches after configuring a new current key. Keep every old key configured until rotation completes.
              </p>
            </div>
            <button
              id="rotate-secret-keys"
              phx-click="rotate-secret-keys"
              data-confirm="Rotate the next batch of encrypted secrets with the configured current key?"
              phx-disable-with="Rotating…"
              class="btn btn-outline btn-sm"
            >
              {if @secret_rotation_cursor, do: "Continue rotation", else: "Rotate keys"}
            </button>
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
