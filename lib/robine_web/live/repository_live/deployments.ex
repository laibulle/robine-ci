defmodule RobineWeb.RepositoryLive.Deployments do
  use RobineWeb, :live_view

  alias Robine.{Deployments, Repositories}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, repositories} <-
           Repositories.list_repositories(%{}, socket.assigns.execution_context),
         repository when not is_nil(repository) <- Enum.find(repositories, &(&1.id == id)),
         {:ok, overview} <-
           Deployments.get_repository_overview(
             %{repository_id: id},
             socket.assigns.execution_context
           ) do
      {:ok,
       socket
       |> assign(
         repository: repository,
         environment_count: length(overview.environments),
         deployment_count: length(overview.deployments),
         environment_form: environment_form(repository),
         environment_error: nil,
         request_forms: request_forms(overview.environments)
       )
       |> stream(:environments, overview.environments)
       |> stream(:deployments, overview.deployments)}
    else
      _reason ->
        {:ok,
         socket
         |> put_flash(:error, "Repository deployments could not be loaded.")
         |> push_navigate(to: ~p"/repositories")}
    end
  end

  @impl true
  def handle_event("save-environment", %{"environment" => params}, socket) do
    input = environment_input(socket.assigns.repository.id, params)

    case Deployments.configure_environment(input, socket.assigns.execution_context) do
      {:ok, _environment} ->
        {:noreply,
         socket
         |> reload_overview()
         |> assign(
           environment_form: environment_form(socket.assigns.repository),
           environment_error: nil
         )
         |> put_flash(:info, "Deployment environment saved with an immutable desired state.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only administrators can configure environments.")}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           environment_form: to_form(params, as: :environment),
           environment_error: environment_error(reason)
         )}
    end
  end

  def handle_event("request-deployment", %{"deployment" => params}, socket) do
    input = %{
      environment_id: params["environment_id"],
      artifact_id: params["artifact_id"],
      kind: normalize_kind(params["kind"])
    }

    case Deployments.request_deployment(input, socket.assigns.execution_context) do
      {:ok, deployment} ->
        message =
          if deployment.status == :awaiting_approval,
            do: "Deployment requested and awaiting independent approval.",
            else: "Deployment queued."

        {:noreply, socket |> reload_overview() |> put_flash(:info, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, deployment_error(reason))}
    end
  end

  def handle_event("approve-deployment", %{"id" => id}, socket) do
    case Deployments.approve_deployment(%{deployment_id: id}, socket.assigns.execution_context) do
      {:ok, _deployment} ->
        {:noreply,
         socket
         |> reload_overview()
         |> put_flash(:info, "Production deployment approved and queued.")}

      {:error, :self_approval} ->
        {:noreply, put_flash(socket, :error, "The requester cannot approve this deployment.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, deployment_error(reason))}
    end
  end

  def handle_event("cancel-deployment", %{"id" => id}, socket) do
    case Deployments.cancel_deployment(%{deployment_id: id}, socket.assigns.execution_context) do
      {:ok, _deployment} ->
        {:noreply,
         socket
         |> reload_overview()
         |> put_flash(:info, "Deployment cancelled. Remote effects were not claimed as reversed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, deployment_error(reason))}
    end
  end

  def handle_event("retry-verification", %{"id" => id}, socket) do
    with {:ok, _deployment} <-
           Deployments.retry_verification(
             %{deployment_id: id},
             socket.assigns.execution_context
           ),
         {:ok, _deployment} <-
           Deployments.verify_deployment(
             %{deployment_id: id},
             socket.assigns.execution_context
           ) do
      {:noreply,
       socket
       |> reload_overview()
       |> put_flash(:info, "Deployment verification succeeded.")}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> reload_overview()
         |> put_flash(:error, deployment_error(reason))}
    end
  end

  defp reload_overview(socket) do
    {:ok, overview} =
      Deployments.get_repository_overview(
        %{repository_id: socket.assigns.repository.id},
        socket.assigns.execution_context
      )

    socket
    |> assign(
      environment_count: length(overview.environments),
      deployment_count: length(overview.deployments),
      request_forms: request_forms(overview.environments)
    )
    |> stream(:environments, overview.environments, reset: true)
    |> stream(:deployments, overview.deployments, reset: true)
  end

  defp environment_form(repository) do
    to_form(
      %{
        "name" => "production",
        "protection" => "protected",
        "runner_labels" => "production, amd64",
        "deployment_root" => "/opt/robine",
        "network_name" => "robine-production",
        "migration_policy" => "forward_only",
        "verification_url" => "https://#{repository.name}.example.test/health/ready",
        "version_path" => "/health/version",
        "application_name" => "server",
        "application_image" => "",
        "secret_key_reference" => "secret-key-base",
        "postgres_enabled" => "true",
        "postgres_image" => "",
        "postgres_volume" => "postgres-data",
        "postgres_password_reference" => "postgres-password",
        "storage_enabled" => "false",
        "storage_image" => "",
        "storage_volume" => "object-storage-data",
        "storage_password_reference" => "object-storage-password",
        "ingress_enabled" => "false",
        "ingress_image" => ""
      },
      as: :environment
    )
  end

  defp request_forms(environments) do
    Map.new(environments, fn environment ->
      {environment.id,
       to_form(
         %{
           "environment_id" => environment.id,
           "artifact_id" => "",
           "kind" => "application"
         },
         as: :deployment,
         id: "deployment-request-#{environment.id}"
       )}
    end)
  end

  defp environment_input(repository_id, params) do
    services =
      [application_service(params)] ++
        optional_service(params["postgres_enabled"], fn -> postgres_service(params) end) ++
        optional_service(params["storage_enabled"], fn -> storage_service(params) end) ++
        optional_service(params["ingress_enabled"], fn -> ingress_service(params) end)

    %{
      repository_id: repository_id,
      name: params["name"],
      protection: params["protection"],
      runner_labels: split_labels(params["runner_labels"]),
      deployment_root: params["deployment_root"],
      network_name: params["network_name"],
      timeout_ms: 1_200_000,
      migration_policy: params["migration_policy"],
      verification: %{
        url: params["verification_url"],
        expected_status: 200..299,
        version_path: blank_to_nil(params["version_path"])
      },
      services: services
    }
  end

  defp application_service(params) do
    %{
      role: :application,
      name: params["application_name"],
      image: params["application_image"],
      command: ["/opt/robine/bin/robine", "start"],
      secret_environment: %{"SECRET_KEY_BASE" => params["secret_key_reference"]},
      healthcheck: %{type: :http, url: "http://server:4000/health/ready"}
    }
  end

  defp postgres_service(params) do
    %{
      role: :postgres,
      name: "postgres",
      image: params["postgres_image"],
      secret_environment: %{"POSTGRES_PASSWORD" => params["postgres_password_reference"]},
      volumes: [%{name: params["postgres_volume"], mount_path: "/var/lib/postgresql"}],
      healthcheck: %{type: :tcp, port: 5432}
    }
  end

  defp storage_service(params) do
    %{
      role: :object_storage,
      name: "object-storage",
      image: params["storage_image"],
      command: ["server", "/data"],
      secret_environment: %{"MINIO_ROOT_PASSWORD" => params["storage_password_reference"]},
      volumes: [%{name: params["storage_volume"], mount_path: "/data"}],
      healthcheck: %{type: :http, url: "http://object-storage:9000/minio/health/live"}
    }
  end

  defp ingress_service(params) do
    %{
      role: :ingress,
      name: "ingress",
      image: params["ingress_image"],
      healthcheck: %{type: :http, url: params["verification_url"]}
    }
  end

  defp optional_service(value, callback) do
    if value in ["true", "on", "1"], do: [callback.()], else: []
  end

  defp split_labels(value) when is_binary(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp split_labels(_value), do: []

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp normalize_kind("platform"), do: :platform
  defp normalize_kind("rollback"), do: :rollback
  defp normalize_kind(_kind), do: :application

  defp environment_error({:invalid_environment, field}),
    do: "Environment configuration is invalid at #{field}. Images must include sha256 digests."

  defp environment_error(_reason), do: "Environment configuration could not be saved."

  defp deployment_error(:artifact_not_deployable),
    do: "Select a retained artifact from a successful semantic-version tag pipeline."

  defp deployment_error(:deployment_already_active),
    do: "This environment already has an active deployment."

  defp deployment_error(:rollback_forbidden),
    do: "Rollback is forbidden by the snapshotted migration policy."

  defp deployment_error(:forbidden), do: "You do not have permission for this action."

  defp deployment_error(reason) when is_atom(reason),
    do: reason |> Atom.to_string() |> String.replace("_", " ")

  defp deployment_error(_reason), do: "The deployment operation could not be completed."

  defp protection_class(:protected), do: "badge-warning"
  defp protection_class(_protection), do: "badge-success"

  defp status_class(:succeeded), do: "badge-success"
  defp status_class(status) when status in [:failed, :verification_failed], do: "badge-error"
  defp status_class(:cancelled), do: "badge-neutral"
  defp status_class(:awaiting_approval), do: "badge-warning"
  defp status_class(_status), do: "badge-info"

  defp active?(status),
    do:
      status in [
        :requested,
        :awaiting_approval,
        :queued,
        :preparing,
        :converging_services
      ]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:repositories}>
      <section class="space-y-8">
        <.page_header
          eyebrow="Promote, don't rebuild"
          title="Native deployments"
          description="Promote one verified artifact digest while keeping PostgreSQL, object storage, ingress, and persistent volumes under explicit control."
          breadcrumbs={[
            %{label: "Repositories", navigate: ~p"/repositories"},
            %{label: @repository.full_name, navigate: ~p"/repositories/#{@repository.id}"},
            %{label: "Deployments"}
          ]}
        >
          <:meta>
            <div class="flex flex-wrap gap-2">
              <span id="environment-count" class="badge badge-outline badge-sm">
                {@environment_count} environments
              </span>
              <span id="deployment-count" class="badge badge-outline badge-sm">
                {@deployment_count} deployments
              </span>
            </div>
          </:meta>
        </.page_header>

        <section class="grid gap-4 lg:grid-cols-3" aria-labelledby="deployment-principles-title">
          <h2 id="deployment-principles-title" class="sr-only">Deployment guarantees</h2>
          <.principle icon="hero-finger-print" title="Digest locked">
            Staging and production consume the same immutable artifact.
          </.principle>
          <.principle icon="hero-circle-stack" title="Volumes preserved">
            Normal deployment operations never remove persistent volumes.
          </.principle>
          <.principle icon="hero-shield-check" title="Independently approved">
            Protected environments reject requester self-approval.
          </.principle>
        </section>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_25rem]">
          <div class="space-y-8">
            <section aria-labelledby="environments-title">
              <div class="flex items-end justify-between border-b border-base-300/70 pb-4">
                <div>
                  <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-primary">
                    Desired state
                  </p>
                  <h2 id="environments-title" class="mt-1 text-2xl font-bold">Environments</h2>
                </div>
              </div>

              <div id="deployment-environments" phx-update="stream" class="mt-4 grid gap-4">
                <div id="deployment-environments-empty" class="hidden only:block">
                  <.ui_state kind={:empty} title="No deployment environment" class="p-10">
                    <p>An administrator can declare the first pinned single-host Docker target.</p>
                  </.ui_state>
                </div>

                <article
                  :for={{dom_id, environment} <- @streams.environments}
                  id={dom_id}
                  class="surface-panel rounded-2xl p-5"
                >
                  <div class="flex flex-wrap items-start justify-between gap-4">
                    <div>
                      <div class="flex items-center gap-2">
                        <h3 class="text-lg font-bold">{environment.name}</h3>
                        <span class={[
                          "badge badge-sm",
                          protection_class(environment.protection)
                        ]}>
                          {environment.protection}
                        </span>
                      </div>
                      <p class="mt-1 font-mono text-xs text-base-content/45">
                        {environment.deployment_root} · {environment.network_name}
                      </p>
                    </div>
                    <code
                      class="max-w-48 truncate rounded-lg bg-base-200 px-2 py-1 text-xs"
                      title={environment.desired_state_digest}
                    >
                      {String.slice(environment.desired_state_digest, 0, 12)}
                    </code>
                  </div>

                  <div class="mt-4 flex flex-wrap gap-2">
                    <span
                      :for={service <- environment.services}
                      class="badge badge-ghost badge-sm gap-1.5"
                    >
                      <span class="size-1.5 rounded-full bg-success"></span>
                      {service.role} · {service.name}
                    </span>
                  </div>

                  <.form
                    for={Map.fetch!(@request_forms, environment.id)}
                    id={"request-deployment-#{environment.id}"}
                    phx-submit="request-deployment"
                    class="mt-5 grid gap-3 rounded-xl border border-base-300/70 bg-base-200/40 p-4 sm:grid-cols-[1fr_10rem_auto]"
                  >
                    <input
                      type="hidden"
                      name="deployment[environment_id]"
                      value={environment.id}
                    />
                    <.input
                      field={Map.fetch!(@request_forms, environment.id)[:artifact_id]}
                      label="Retained artifact ID"
                      placeholder="UUID from a successful tag pipeline"
                      required
                    />
                    <.input
                      field={Map.fetch!(@request_forms, environment.id)[:kind]}
                      type="select"
                      label="Operation"
                      options={[
                        {"Application", "application"},
                        {"Platform", "platform"},
                        {"Rollback", "rollback"}
                      ]}
                    />
                    <button
                      id={"submit-deployment-#{environment.id}"}
                      class="btn btn-primary self-end"
                      phx-disable-with="Requesting…"
                    >Request</button>
                  </.form>
                </article>
              </div>
            </section>

            <section aria-labelledby="deployment-history-title">
              <div class="border-b border-base-300/70 pb-4">
                <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-primary">
                  Durable timeline
                </p>
                <h2 id="deployment-history-title" class="mt-1 text-2xl font-bold">
                  Deployment history
                </h2>
              </div>

              <div id="deployments" phx-update="stream" class="mt-4 grid gap-3">
                <div id="deployments-empty" class="hidden only:block">
                  <.ui_state kind={:empty} title="No deployment requested" class="p-10" />
                </div>
                <article
                  :for={{dom_id, deployment} <- @streams.deployments}
                  id={dom_id}
                  class="surface-panel rounded-2xl p-5"
                >
                  <div class="flex flex-wrap items-start justify-between gap-4">
                    <div>
                      <div class="flex flex-wrap items-center gap-2">
                        <span class={["badge badge-sm", status_class(deployment.status)]}>
                          {deployment.status}
                        </span>
                        <span class="badge badge-ghost badge-sm">{deployment.kind}</span>
                        <span class="font-mono text-xs font-bold text-primary">
                          {deployment.artifact.tag}
                        </span>
                      </div>
                      <p class="mt-3 font-mono text-sm">{deployment.artifact.filename}</p>
                      <p
                        class="mt-1 font-mono text-xs text-base-content/45"
                        title={deployment.artifact.digest}
                      >
                        sha256:{String.slice(deployment.artifact.digest, 0, 16)}…
                      </p>
                    </div>
                    <div class="flex flex-wrap gap-2">
                      <button
                        :if={
                          deployment.status == :awaiting_approval &&
                            @current_actor.role == :administrator
                        }
                        id={"approve-deployment-#{deployment.id}"}
                        phx-click="approve-deployment"
                        phx-value-id={deployment.id}
                        class="btn btn-primary btn-sm"
                        phx-disable-with="Approving…"
                      >Approve</button>
                      <button
                        :if={active?(deployment.status)}
                        id={"cancel-deployment-#{deployment.id}"}
                        phx-click="cancel-deployment"
                        phx-value-id={deployment.id}
                        class="btn btn-ghost btn-sm text-error"
                        phx-disable-with="Cancelling…"
                      >Cancel</button>
                      <button
                        :if={
                          deployment.status == :verification_failed &&
                            @current_actor.role == :administrator
                        }
                        id={"retry-verification-#{deployment.id}"}
                        phx-click="retry-verification"
                        phx-value-id={deployment.id}
                        class="btn btn-outline btn-sm"
                        phx-disable-with="Verifying…"
                      >Retry verification</button>
                    </div>
                  </div>
                </article>
              </div>
            </section>
          </div>

          <aside :if={@current_actor.role == :administrator} class="xl:sticky xl:top-6 xl:self-start">
            <section
              class="surface-panel overflow-hidden rounded-2xl"
              aria-labelledby="environment-form-title"
            >
              <div class="border-b border-base-300/70 bg-base-200/60 p-5">
                <h2 id="environment-form-title" class="font-bold">Configure environment</h2>
                <p class="mt-1 text-xs text-base-content/50">
                  Re-saving a name replaces its desired state, never its volumes.
                </p>
              </div>

              <.form
                for={@environment_form}
                id="deployment-environment-form"
                phx-submit="save-environment"
                class="space-y-5 p-5"
              >
                <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-1 2xl:grid-cols-2">
                  <.input field={@environment_form[:name]} label="Name" required />
                  <.input
                    field={@environment_form[:protection]}
                    type="select"
                    label="Protection"
                    options={[{"Protected", "protected"}, {"Unprotected", "unprotected"}]}
                  />
                </div>
                <.input field={@environment_form[:runner_labels]} label="Runner labels" required />
                <.input field={@environment_form[:deployment_root]} label="Deployment root" required />
                <.input field={@environment_form[:network_name]} label="Docker network" required />
                <.input
                  field={@environment_form[:migration_policy]}
                  type="select"
                  label="Migration policy"
                  options={[
                    {"Forward only", "forward_only"},
                    {"Rollback safe", "rollback_safe"},
                    {"Application only", "application_only"}
                  ]}
                />
                <.input
                  field={@environment_form[:verification_url]}
                  type="url"
                  label="Health URL"
                  required
                />
                <.input field={@environment_form[:version_path]} label="Version path" />

                <fieldset class="space-y-4 rounded-xl border border-base-300/70 p-4">
                  <legend class="px-1 text-sm font-bold">Application</legend>
                  <.input
                    field={@environment_form[:application_name]}
                    label="Container name"
                    required
                  />
                  <.input
                    field={@environment_form[:application_image]}
                    label="Pinned runtime image"
                    placeholder="image@sha256:…"
                    required
                  />
                  <.input
                    field={@environment_form[:secret_key_reference]}
                    label="SECRET_KEY_BASE secret"
                    required
                  />
                </fieldset>

                <fieldset class="space-y-4 rounded-xl border border-base-300/70 p-4">
                  <legend class="px-1 text-sm font-bold">PostgreSQL</legend>
                  <.input
                    field={@environment_form[:postgres_enabled]}
                    type="checkbox"
                    label="Manage PostgreSQL"
                  />
                  <.input
                    field={@environment_form[:postgres_image]}
                    label="Pinned image"
                    placeholder="postgres@sha256:…"
                  />
                  <.input field={@environment_form[:postgres_volume]} label="Persistent volume" />
                  <.input
                    field={@environment_form[:postgres_password_reference]}
                    label="Password secret"
                  />
                </fieldset>

                <details class="rounded-xl border border-base-300/70 p-4">
                  <summary class="cursor-pointer text-sm font-bold">
                    Object storage and ingress
                  </summary>
                  <div class="mt-4 space-y-4">
                    <.input
                      field={@environment_form[:storage_enabled]}
                      type="checkbox"
                      label="Manage S3-compatible storage"
                    />
                    <.input field={@environment_form[:storage_image]} label="Pinned storage image" />
                    <.input field={@environment_form[:storage_volume]} label="Storage volume" />
                    <.input
                      field={@environment_form[:storage_password_reference]}
                      label="Storage password secret"
                    />
                    <.input
                      field={@environment_form[:ingress_enabled]}
                      type="checkbox"
                      label="Manage ingress"
                    />
                    <.input field={@environment_form[:ingress_image]} label="Pinned ingress image" />
                  </div>
                </details>

                <p
                  :if={@environment_error}
                  id="environment-error"
                  class="text-sm text-error"
                  role="alert"
                >
                  {@environment_error}
                </p>
                <div class="alert alert-warning items-start text-xs">
                  <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
                  <span>Platform changes are explicit. Persistent volumes are never removed automatically.</span>
                </div>
                <button
                  id="save-deployment-environment"
                  class="btn btn-primary w-full"
                  phx-disable-with="Saving…"
                >
                  Save desired state
                </button>
              </.form>
            </section>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp principle(assigns) do
    ~H"""
    <article class="rounded-2xl border border-base-300/70 bg-base-100 p-5 shadow-sm">
      <span class="grid size-10 place-items-center rounded-xl bg-primary/10 text-primary">
        <.icon name={@icon} class="size-5" />
      </span>
      <h2 class="mt-4 font-bold">{@title}</h2>
      <p class="mt-1 text-sm leading-6 text-base-content/60">{render_slot(@inner_block)}</p>
    </article>
    """
  end
end
