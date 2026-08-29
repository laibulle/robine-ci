defmodule RobineWeb.AdminLive.Index do
  use RobineWeb, :live_view
  alias Robine.{Autoscaling, Identities, Operations, Runners, Secrets}

  @sections ~w(overview runners source-control security users)

  @impl true
  def mount(_params, _session, socket), do: {:ok, load(socket)}

  @impl true
  def handle_params(params, _uri, socket) do
    section = if params["section"] in @sections, do: params["section"], else: "overview"
    {:noreply, assign(socket, :admin_section, section)}
  end

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

  def handle_event("github-setup-step", %{"step" => step}, socket) do
    case Integer.parse(step) do
      {number, ""} when number in 1..4 -> {:noreply, assign(socket, github_setup_step: number)}
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("verify-github-setup", _params, socket) do
    {:noreply, socket |> assign(github_setup_step: 4) |> load_health()}
  end

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
        runner_installer_url: runner_installer_url(),
        runner_windows_installer_url: runner_windows_installer_url(),
        runner_enrollment: Map.get(socket.assigns, :runner_enrollment),
        runner_credential: Map.get(socket.assigns, :runner_credential),
        github_setup_step: Map.get(socket.assigns, :github_setup_step, 1),
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
          runner_installer_url: runner_installer_url(),
          runner_windows_installer_url: runner_windows_installer_url(),
          runner_enrollment: Map.get(socket.assigns, :runner_enrollment),
          runner_credential: Map.get(socket.assigns, :runner_credential),
          github_setup_step: Map.get(socket.assigns, :github_setup_step, 1),
          secret_rotation_cursor: Map.get(socket.assigns, :secret_rotation_cursor)
        )
        |> stream(:runners, [], reset: true)
        |> stream(:autoscaling_policies, [], reset: true)
        |> load_health()
    end
  end

  defp load_health(socket) do
    case Operations.health(%{}, socket.assigns.execution_context) do
      {:ok, health} ->
        public_health = update_in(health.checks, &Map.drop(&1, [:gitlab, :forgejo]))
        assign(socket, health: public_health, github_setup: github_setup_projection(health))

      {:error, _reason} ->
        health = %{status: :not_ready, checks: %{}}
        assign(socket, health: health, github_setup: github_setup_projection(health))
    end
  end

  defp runner_installer_url do
    public_url = Application.fetch_env!(:robine, :public_url) |> String.trim_trailing("/")
    public_url <> "/install/rbe.sh"
  end

  defp runner_windows_installer_url do
    public_url = Application.fetch_env!(:robine, :public_url) |> String.trim_trailing("/")
    public_url <> "/install/rbe.ps1"
  end

  defp windows_enrollment_command(enrollment) do
    public_url = Application.fetch_env!(:robine, :public_url)

    "$env:RBE_SERVER_URL='#{public_url}'; irm '#{runner_windows_installer_url()}' | iex; " <>
      "$env:ROBINE_RUNNER_ENROLLMENT_TOKEN='#{enrollment.token}'; " <>
      "try { & \"$HOME\\.local\\bin\\rbe.exe\" enroll --server '#{public_url}' " <>
      "--name $env:COMPUTERNAME --config \"$HOME\\.config\\robine-runner\\config.json\" --force; " <>
      "$enrollStatus=$LASTEXITCODE } finally { Remove-Item Env:ROBINE_RUNNER_ENROLLMENT_TOKEN }; " <>
      "if ($enrollStatus -ne 0) { exit $enrollStatus }; " <>
      "& \"$HOME\\.local\\bin\\rbe.exe\" start --config \"$HOME\\.config\\robine-runner\\config.json\""
  end

  defp github_setup_projection(health) do
    public_url = Application.fetch_env!(:robine, :public_url) |> String.trim_trailing("/")
    github_health = get_in(health, [:checks, :github_app])

    %{
      public_url: public_url,
      webhook_url: public_url <> "/api/github/webhooks",
      private_key_default: Application.get_env(:robine, :dev_github_private_key_form_default, ""),
      webhook_secret_default:
        Application.get_env(:robine, :dev_github_webhook_secret_form_default, ""),
      app_id_configured?: Application.get_env(:robine, :github_app_id) not in [nil, ""],
      healthy?: is_map(github_health) and github_health.status == :ok,
      health_detail:
        if(is_map(github_health), do: github_health.detail, else: "Health check unavailable")
    }
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
  defp check_label(:docker), do: "Docker execution"
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
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:admin}>
      <section class="space-y-8">
        <.page_header
          eyebrow="The engine room"
          title="Administration"
          description="Keep the machinery healthy, the boundaries explicit, and your instance unmistakably yours."
        >
          <:actions>
            <.link
              navigate={~p"/admin/api-tokens"}
              id="admin-api-tokens"
              class="btn btn-outline btn-sm"
            >API tokens</.link>
          </:actions>
        </.page_header>
        <nav
          id="admin-section-navigation"
          class="grid gap-1 rounded-2xl border border-base-300/70 bg-base-100/75 p-1.5 sm:grid-cols-5"
          aria-label="Administration sections"
        >
          <.link
            :for={
              {id, label, icon} <- [
                {"overview", "Overview", "hero-squares-2x2"},
                {"runners", "Runners", "hero-cpu-chip"},
                {"source-control", "Source control", "hero-code-bracket-square"},
                {"security", "Security", "hero-shield-check"},
                {"users", "Users", "hero-users"}
              ]
            }
            id={"admin-section-#{id}"}
            patch={"/admin?section=#{id}"}
            aria-current={@admin_section == id && "page"}
            class={[
              "flex items-center justify-center gap-2 rounded-xl px-3 py-2.5 text-xs font-bold transition",
              @admin_section == id && "bg-primary/15 text-base-content shadow-sm",
              @admin_section != id && "text-base-content/50 hover:bg-base-200 hover:text-base-content"
            ]}
          ><.icon name={icon} class="size-4" />{label}</.link>
        </nav>
        <section
          :if={@admin_section == "overview"}
          class="surface-panel rounded-2xl p-6"
        >
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
        <section :if={@admin_section == "runners"} class="surface-panel rounded-2xl p-6">
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
        <section :if={@admin_section == "runners"} class="surface-panel rounded-2xl p-6">
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
                <div :if={runner.admin_state != :revoked} class="flex flex-wrap items-center gap-2">
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
                  <div
                    class="ml-1 flex gap-2 border-l border-error/25 pl-3"
                    aria-label="Sensitive runner actions"
                  >
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
        <section :if={@admin_section == "runners"} class="surface-panel rounded-2xl p-6">
          <div
            id="runner-installation"
            class="rounded-2xl border border-base-300 bg-base-200/40 p-4"
          >
            <div class="flex items-start gap-3">
              <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-primary/10 text-primary">
                <.icon name="hero-arrow-down-tray" class="size-5" />
              </span>
              <div class="min-w-0 flex-1">
                <h2 class="text-lg font-semibold">Install rbe</h2>
                <p class="mt-1 text-sm leading-6 text-base-content/60">
                  Robine detects macOS or Linux and the host architecture, verifies the GitHub Release SHA-256, installs
                  <code>rbe</code>
                  and safely reconciles launchd or a systemd user service without a package manager. Windows uses the verified PowerShell installer below.
                </p>
                <p class="mt-3 text-xs font-bold uppercase tracking-[0.14em] text-base-content/45">
                  macOS or Linux
                </p>
                <pre
                  id="runner-posix-install-command"
                  class="mt-3 overflow-x-auto whitespace-pre-wrap break-all rounded-xl bg-base-300 p-3 text-xs"
                ><code>curl --proto '=https' --tlsv1.2 -fsSL '{@runner_installer_url}' | RBE_SERVER_URL='{Application.fetch_env!(:robine, :public_url)}' /bin/bash</code></pre>
                <p class="mt-4 text-xs font-bold uppercase tracking-[0.14em] text-base-content/45">
                  Windows PowerShell
                </p>
                <pre
                  id="runner-windows-install-command"
                  class="mt-3 overflow-x-auto whitespace-pre-wrap break-all rounded-xl bg-base-300 p-3 text-xs"
                ><code>$env:RBE_SERVER_URL='{Application.fetch_env!(:robine, :public_url)}'; irm '{@runner_windows_installer_url}' | iex</code></pre>
              </div>
            </div>
          </div>
          <div class="mt-6 flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">Remote runner enrollment</h2>
              <p class="mt-1 max-w-3xl text-sm text-base-content/60">
                Generate a single-use token valid for 15 minutes. The one-time command installs <code>rbe</code>, enrolls this host, then starts launchd or systemd where supported; Windows remains in the foreground.
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
              Run the command for the trusted host. Its host name becomes the runner name, and
              any config at the standard path is explicitly replaced. The token expires at {DateTime.to_iso8601(
                @runner_enrollment.expires_at
              )}.
            </p>
            <pre
              id="runner-enrollment-command"
              class="mt-3 overflow-x-auto whitespace-pre-wrap break-all rounded-xl bg-base-300 p-3 text-xs"
            ><code>curl --proto '=https' --tlsv1.2 -fsSL '{@runner_installer_url}' | RBE_SERVER_URL='{Application.fetch_env!(:robine, :public_url)}' RBE_SKIP_SERVICE_INSTALL=1 /bin/bash &amp;&amp; ROBINE_RUNNER_ENROLLMENT_TOKEN='{@runner_enrollment.token}' "$HOME/.local/bin/rbe" enroll --server '{Application.fetch_env!(:robine, :public_url)}' --name "$(scutil --get ComputerName 2&gt;/dev/null || hostname -s)" --config "$HOME/.config/robine-runner/config.json" --force &amp;&amp; "$HOME/.local/bin/rbe" install --config "$HOME/.config/robine-runner/config.json" --server '{Application.fetch_env!(:robine, :public_url)}'</code></pre>
            <p class="mt-4 text-xs font-bold uppercase tracking-[0.14em] text-base-content/45">
              Windows PowerShell
            </p>
            <pre
              id="runner-windows-enrollment-command"
              class="mt-3 overflow-x-auto whitespace-pre-wrap break-all rounded-xl bg-base-300 p-3 text-xs"
            ><code>{windows_enrollment_command(@runner_enrollment)}</code></pre>
          </div>
        </section>
        <section
          :if={@admin_section == "source-control"}
          id="github-setup-assistant"
          class="surface-panel overflow-hidden rounded-2xl"
        >
          <div class="border-b border-base-300/70 bg-base-200/40 p-6 sm:p-8">
            <div class="flex flex-wrap items-start justify-between gap-4">
              <div>
                <p class="page-eyebrow">Guided integration</p>
                <h2 class="mt-3 text-2xl font-semibold">Connect GitHub</h2>
                <p class="mt-2 max-w-2xl text-sm leading-6 text-base-content/55">
                  Create a least-privilege GitHub App, connect it securely, then choose which repositories Robine may run.
                </p>
              </div>
              <span class={[
                "badge gap-2 px-3 py-3",
                @github_setup.healthy? && "badge-success",
                !@github_setup.healthy? && "badge-warning"
              ]}>
                <span class="size-1.5 rounded-full bg-current"></span>
                {if @github_setup.healthy?, do: "Connected", else: "Setup required"}
              </span>
            </div>

            <ol class="mt-7 grid gap-2 sm:grid-cols-4" aria-label="GitHub setup steps">
              <li :for={
                {label, number} <-
                  Enum.with_index(["Create app", "Permissions", "Credentials", "Verify"], 1)
              }>
                <button
                  id={"github-setup-step-#{number}"}
                  type="button"
                  phx-click="github-setup-step"
                  phx-value-step={number}
                  aria-current={@github_setup_step == number && "step"}
                  class={[
                    "flex w-full items-center gap-2 rounded-xl px-3 py-2.5 text-left text-xs font-bold transition",
                    @github_setup_step == number && "bg-base-content text-base-100 shadow-sm",
                    @github_setup_step != number &&
                      "text-base-content/45 hover:bg-base-100 hover:text-base-content"
                  ]}
                >
                  <span class={[
                    "grid size-6 shrink-0 place-items-center rounded-full border text-[0.65rem]",
                    @github_setup_step == number && "border-primary bg-primary text-primary-content",
                    @github_setup_step != number && "border-base-300"
                  ]}>{number}</span>
                  {label}
                </button>
              </li>
            </ol>
          </div>

          <div class="p-6 sm:p-8">
            <section
              :if={@github_setup_step == 1}
              id="github-setup-create"
              aria-labelledby="github-setup-create-title"
            >
              <div class="grid gap-8 lg:grid-cols-[1fr_0.85fr]">
                <div>
                  <p class="text-xs font-bold uppercase tracking-[0.14em] text-primary">
                    Step 1 of 4
                  </p>
                  <h3 id="github-setup-create-title" class="mt-2 text-xl font-semibold">
                    Create the GitHub App
                  </h3>
                  <p class="mt-2 text-sm leading-6 text-base-content/55">
                    In GitHub, create a new App owned by the organization that contains the repositories you want to connect.
                  </p>
                  <a
                    href="https://github.com/settings/apps/new"
                    target="_blank"
                    rel="noreferrer"
                    class="btn btn-primary mt-6 gap-2"
                  >
                    Create GitHub App <.icon name="hero-arrow-up-right" class="size-4" />
                  </a>
                </div>
                <div class="rounded-2xl border border-base-300/70 bg-base-200/45 p-5">
                  <p class="text-sm font-semibold">Values to enter in GitHub</p>
                  <div class="mt-4 space-y-4">
                    <label
                      class="block text-xs font-semibold text-base-content/55"
                      for="github-homepage-url"
                    >Homepage URL</label>
                    <input
                      id="github-homepage-url"
                      value={@github_setup.public_url}
                      readonly
                      class="input input-bordered -mt-2 w-full font-mono text-xs"
                    />
                    <label
                      class="block text-xs font-semibold text-base-content/55"
                      for="github-webhook-url"
                    >Webhook URL</label>
                    <input
                      id="github-webhook-url"
                      value={@github_setup.webhook_url}
                      readonly
                      class="input input-bordered -mt-2 w-full font-mono text-xs"
                    />
                    <p class="flex gap-2 text-xs leading-5 text-base-content/45">
                      <.icon name="hero-information-circle" class="mt-0.5 size-4 shrink-0" />Keep “Active” enabled. You will create the webhook secret in step 3.
                    </p>
                  </div>
                </div>
              </div>
              <div class="mt-8 flex justify-end border-t border-base-300/70 pt-5">
                <button
                  type="button"
                  phx-click="github-setup-step"
                  phx-value-step="2"
                  class="btn btn-primary gap-2"
                >Continue to permissions <.icon name="hero-arrow-right" class="size-4" /></button>
              </div>
            </section>

            <section
              :if={@github_setup_step == 2}
              id="github-setup-permissions"
              aria-labelledby="github-setup-permissions-title"
            >
              <p class="text-xs font-bold uppercase tracking-[0.14em] text-primary">Step 2 of 4</p>
              <h3 id="github-setup-permissions-title" class="mt-2 text-xl font-semibold">
                Apply least-privilege access
              </h3>
              <p class="mt-2 text-sm leading-6 text-base-content/55">
                In “Permissions & events”, configure exactly the following values.
              </p>
              <div class="mt-6 grid gap-4 lg:grid-cols-2">
                <div class="rounded-2xl border border-base-300/70 p-5">
                  <div class="flex items-center gap-3">
                    <span class="grid size-9 place-items-center rounded-xl bg-primary/10 text-primary"><.icon
                      name="hero-key"
                      class="size-4"
                    /></span><h4 class="font-semibold">Repository permissions</h4>
                  </div>
                  <dl class="mt-5 space-y-3 text-sm">
                    <div class="flex items-center justify-between gap-4">
                      <dt>Metadata</dt><dd class="badge badge-ghost">Read-only</dd>
                    </div>
                    <div class="flex items-center justify-between gap-4">
                      <dt>Contents</dt><dd class="badge badge-primary">Read &amp; write</dd>
                    </div>
                    <div class="flex items-center justify-between gap-4">
                      <dt>Pull requests</dt><dd class="badge badge-ghost">Read-only</dd>
                    </div>
                    <div class="flex items-center justify-between gap-4">
                      <dt>Checks</dt><dd class="badge badge-primary">Read & write</dd>
                    </div>
                  </dl>
                </div>
                <div class="rounded-2xl border border-base-300/70 p-5">
                  <div class="flex items-center gap-3">
                    <span class="grid size-9 place-items-center rounded-xl bg-primary/10 text-primary"><.icon
                      name="hero-bell"
                      class="size-4"
                    /></span><h4 class="font-semibold">Subscribe to events</h4>
                  </div>
                  <ul class="mt-5 space-y-3 text-sm">
                    <li class="flex items-center gap-2">
                      <.icon name="hero-check-circle" class="size-4 text-primary" /> Push
                    </li>
                    <li class="flex items-center gap-2">
                      <.icon name="hero-check-circle" class="size-4 text-primary" /> Pull request
                    </li>
                  </ul>
                  <p class="mt-5 text-xs leading-5 text-base-content/45">
                    No organization or account permissions are required.
                  </p>
                </div>
              </div>
              <div class="mt-8 flex justify-between border-t border-base-300/70 pt-5">
                <button
                  type="button"
                  phx-click="github-setup-step"
                  phx-value-step="1"
                  class="btn btn-ghost"
                >Back</button>
                <button
                  type="button"
                  phx-click="github-setup-step"
                  phx-value-step="3"
                  class="btn btn-primary gap-2"
                >Continue to credentials <.icon name="hero-arrow-right" class="size-4" /></button>
              </div>
            </section>

            <section
              :if={@github_setup_step == 3}
              id="github-setup-credentials"
              aria-labelledby="github-setup-credentials-title"
            >
              <p class="text-xs font-bold uppercase tracking-[0.14em] text-primary">Step 3 of 4</p>
              <h3 id="github-setup-credentials-title" class="mt-2 text-xl font-semibold">
                Connect the credentials
              </h3>
              <p class="mt-2 max-w-3xl text-sm leading-6 text-base-content/55">
                Create a private key from the App settings and use the same webhook secret in GitHub and below. Both values are encrypted and write-only.
              </p>

              <div class="mt-6 rounded-2xl border border-base-300/70 bg-base-200/45 p-4">
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <p class="text-sm font-semibold">App ID</p><p class="mt-1 text-xs text-base-content/50">
                      Set <code>GITHUB_APP_ID</code> in the Robine server environment, then restart.
                    </p>
                  </div>
                  <span class={[
                    @github_setup.app_id_configured? && "badge badge-success",
                    !@github_setup.app_id_configured? && "badge badge-warning"
                  ]}>{if @github_setup.app_id_configured?, do: "Configured", else: "Missing"}</span>
                </div>
              </div>

              <div class="mt-5 grid gap-5 lg:grid-cols-2">
                <form
                  id="github-private-key-form"
                  phx-submit="save-github-private-key"
                  class="rounded-2xl border border-base-300/70 p-5"
                >
                  <label for="github-private-key" class="font-semibold">Private key (PEM)</label>
                  <p class="mt-1 text-xs leading-5 text-base-content/45">
                    Download a new private key at the bottom of the App settings page, then paste its full contents.
                  </p>
                  <textarea
                    id="github-private-key"
                    name="value"
                    required
                    minlength="8"
                    maxlength="65536"
                    autocomplete="off"
                    spellcheck="false"
                    placeholder="-----BEGIN RSA PRIVATE KEY-----"
                    class="textarea textarea-bordered mt-4 min-h-36 w-full font-mono text-xs"
                  >{@github_setup.private_key_default}</textarea>
                  <button class="btn btn-primary btn-sm mt-3" phx-disable-with="Encrypting…">Store private key</button>
                </form>
                <form
                  id="github-webhook-secret-form"
                  phx-submit="save-github-webhook-secret"
                  class="rounded-2xl border border-base-300/70 p-5"
                >
                  <label for="github-webhook-secret" class="font-semibold">Webhook secret</label>
                  <p class="mt-1 text-xs leading-5 text-base-content/45">
                    Use a unique random value of at least 32 characters and paste that same value into GitHub.
                  </p>
                  <input
                    id="github-webhook-secret"
                    type="password"
                    name="value"
                    value={@github_setup.webhook_secret_default}
                    required
                    minlength="8"
                    maxlength="65536"
                    autocomplete="new-password"
                    placeholder="Paste the shared webhook secret"
                    class="input input-bordered mt-4 w-full"
                  />
                  <button class="btn btn-primary btn-sm mt-3" phx-disable-with="Encrypting…">Store webhook secret</button>
                </form>
              </div>
              <div class="mt-8 flex justify-between border-t border-base-300/70 pt-5">
                <button
                  type="button"
                  phx-click="github-setup-step"
                  phx-value-step="2"
                  class="btn btn-ghost"
                >Back</button>
                <button
                  id="verify-github-setup"
                  type="button"
                  phx-click="verify-github-setup"
                  class="btn btn-primary gap-2"
                  phx-disable-with="Checking…"
                >Verify connection <.icon name="hero-arrow-path" class="size-4" /></button>
              </div>
            </section>

            <section
              :if={@github_setup_step == 4}
              id="github-setup-verify"
              aria-labelledby="github-setup-verify-title"
            >
              <p class="text-xs font-bold uppercase tracking-[0.14em] text-primary">Step 4 of 4</p>
              <h3 id="github-setup-verify-title" class="mt-2 text-xl font-semibold">
                Verify and install
              </h3>
              <div
                class={[
                  "mt-6 flex gap-4 rounded-2xl border p-5",
                  @github_setup.healthy? && "border-success/30 bg-success/10",
                  !@github_setup.healthy? && "border-warning/30 bg-warning/10"
                ]}
                role={if @github_setup.healthy?, do: "status", else: "alert"}
              >
                <span class={[
                  "grid size-10 shrink-0 place-items-center rounded-full",
                  @github_setup.healthy? && "bg-success text-success-content",
                  !@github_setup.healthy? && "bg-warning text-warning-content"
                ]}><.icon
                  name={
                    if @github_setup.healthy?, do: "hero-check", else: "hero-exclamation-triangle"
                  }
                  class="size-5"
                /></span>
                <div>
                  <p class="font-semibold">
                    {if @github_setup.healthy?,
                      do: "GitHub App connected",
                      else: "Connection needs attention"}
                  </p><p class="mt-1 text-sm leading-6 opacity-70">{@github_setup.health_detail}</p>
                </div>
              </div>
              <div class="mt-6 grid gap-4 sm:grid-cols-2">
                <a
                  href="https://github.com/settings/installations"
                  target="_blank"
                  rel="noreferrer"
                  class="group rounded-2xl border border-base-300/70 p-5 transition hover:border-primary/35 hover:bg-primary/5"
                ><span class="grid size-9 place-items-center rounded-xl bg-base-200 text-primary"><.icon
                  name="hero-building-library"
                  class="size-4"
                /></span><h4 class="mt-4 font-semibold">Install on repositories</h4><p class="mt-1 text-sm leading-6 text-base-content/50">
                  Choose the organization and grant access only to repositories Robine should run.
                </p></a>
                <.link
                  navigate={~p"/repositories"}
                  class="group rounded-2xl border border-base-300/70 p-5 transition hover:border-primary/35 hover:bg-primary/5"
                ><span class="grid size-9 place-items-center rounded-xl bg-base-200 text-primary"><.icon
                  name="hero-code-bracket-square"
                  class="size-4"
                /></span><h4 class="mt-4 font-semibold">Trust repositories in Robine</h4><p class="mt-1 text-sm leading-6 text-base-content/50">
                  Discover the installation and explicitly enable your first repository.
                </p></.link>
              </div>
              <div class="mt-8 flex justify-between border-t border-base-300/70 pt-5">
                <button
                  type="button"
                  phx-click="github-setup-step"
                  phx-value-step="3"
                  class="btn btn-ghost"
                >Back to credentials</button>
                <button
                  type="button"
                  phx-click="verify-github-setup"
                  class="btn btn-outline gap-2"
                  phx-disable-with="Checking…"
                ><.icon name="hero-arrow-path" class="size-4" /> Check again</button>
              </div>
            </section>
          </div>
        </section>
        <section :if={@admin_section == "security"} class="surface-panel rounded-2xl p-6">
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
        <section :if={@admin_section == "overview"} class="surface-panel rounded-2xl p-6">
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
        <section :if={@admin_section == "security"} class="surface-panel rounded-2xl p-6">
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
        <section :if={@admin_section == "users"} class="surface-panel rounded-2xl p-6">
          <h2 class="text-xl font-semibold">Users and roles</h2><div class="mt-4 overflow-x-auto rounded-xl border border-base-300 bg-base-100">
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
