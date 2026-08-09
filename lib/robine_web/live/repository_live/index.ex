defmodule RobineWeb.RepositoryLive.Index do
  use RobineWeb, :live_view
  alias Robine.Repositories

  @impl true
  def mount(_params, _session, socket) do
    {repositories, repository_load_error} =
      case Repositories.list_repositories(%{}, socket.assigns.execution_context) do
        {:ok, values} -> {values, false}
        {:error, _reason} -> {[], true}
      end

    {:ok,
     assign(socket,
       repositories: repositories,
       repository_load_error: repository_load_error,
       available_repositories: [],
       discovery_state: :not_run
     )}
  end

  @impl true
  def handle_event("discover", _params, socket) do
    case Repositories.discover_github_repositories(%{}, socket.assigns.execution_context) do
      {:ok, repositories} ->
        {:noreply, assign(socket, available_repositories: repositories, discovery_state: :ready)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only administrators can connect repositories.")}

      {:error, _reason} ->
        {:noreply, assign(socket, available_repositories: [], discovery_state: :error)}
    end
  end

  def handle_event("trust", params, socket) do
    input = %{
      provider_id: params["provider_id"],
      installation_id: params["installation_id"],
      full_name: params["full_name"]
    }

    case Repositories.trust_github_repository(input, socket.assigns.execution_context) do
      {:ok, repository} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{repository.full_name} is now trusted.")
         |> assign(
           repositories: load_repositories(socket),
           available_repositories:
             Enum.reject(
               socket.assigns.available_repositories,
               &(&1.provider_id == String.to_integer(params["provider_id"]))
             )
         )}

      {:error, :repository_not_granted_to_github_app} ->
        {:noreply,
         put_flash(socket, :error, "GitHub no longer grants the App access to that repository.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The repository could not be trusted.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header>
          <p class="text-sm font-semibold uppercase tracking-[0.2em] text-primary">Source control</p><h1 class="mt-2 text-4xl font-bold">
            Repositories
          </h1><p class="mt-2 text-base-content/60">
            Only explicitly trusted GitHub App installations execute workflows.
          </p>
        </header>
        <section
          :if={@current_actor.role == :administrator}
          class="rounded-3xl border border-base-300 bg-base-100 p-6"
          aria-labelledby="github-repository-selection"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 id="github-repository-selection" class="text-xl font-semibold">
                GitHub App repositories
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                Refresh live App access, then explicitly trust only repositories that may run CI.
              </p>
            </div>
            <button
              id="discover-github-repositories"
              phx-click="discover"
              phx-disable-with="Refreshing…"
              class="btn btn-primary"
            >
              Refresh installations
            </button>
          </div>
          <p :if={@discovery_state == :not_run} class="mt-5 text-sm text-base-content/60">
            No GitHub access has been queried in this browser session.
          </p>
          <.ui_state
            :if={@discovery_state == :error}
            kind={:degraded}
            title="GitHub installations are unavailable"
            class="mt-5"
          >
            Check App credentials and connectivity, then try again. Trusted repositories remain active.
          </.ui_state>
          <.ui_state
            :if={@discovery_state == :ready and @available_repositories == []}
            kind={:empty}
            title="No repository is granted to this GitHub App"
            class="mt-5 p-6"
          >
            Update the installation's repository access in GitHub, then refresh.
          </.ui_state>
          <ul :if={@available_repositories != []} class="mt-5 grid gap-3">
            <li
              :for={repository <- @available_repositories}
              id={"available-repository-#{repository.provider_id}"}
              class="flex flex-wrap items-center justify-between gap-4 rounded-2xl border border-base-300 p-4"
            >
              <div>
                <p class="font-semibold">{repository.full_name}</p>
                <p class="text-xs text-base-content/55">
                  Installation {repository.installation_id} · {if repository.private,
                    do: "Private",
                    else: "Public"}
                </p>
              </div>
              <button
                phx-click="trust"
                phx-disable-with="Verifying…"
                phx-value-provider_id={repository.provider_id}
                phx-value-installation_id={repository.installation_id}
                phx-value-full_name={repository.full_name}
                class="btn btn-sm"
              >Trust repository</button>
            </li>
          </ul>
        </section>
        <.ui_state
          :if={@repository_load_error}
          kind={:error}
          title="Trusted repositories are temporarily unavailable"
          class="rounded-3xl p-12"
        >
          Reload the page after checking database health. Repository discovery does not change existing trust.
        </.ui_state>
        <.ui_state
          :if={@repositories == [] and not @repository_load_error}
          kind={:empty}
          title="No trusted repository"
          class="rounded-3xl p-12"
        >
          Install the GitHub App, refresh installations, then explicitly trust a selected repository.
        </.ui_state>
        <div :if={@repositories != []} class="grid gap-4 md:grid-cols-2">
          <article
            :for={repository <- @repositories}
            id={"repository-#{repository.id}"}
            class="rounded-3xl border border-base-300 bg-base-100 p-6"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <p class="text-sm text-base-content/55">GitHub</p><.link
                  navigate={~p"/repositories/#{repository.id}"}
                  class="mt-1 block text-xl font-semibold link link-hover"
                >{repository.full_name}</.link>
              </div><span class={["badge", repository.trusted && "badge-success"]}>{if repository.trusted,
                do: "Trusted",
                else: "Disabled"}</span>
            </div><p class="mt-5 text-sm text-base-content/60">
              Connected {Calendar.strftime(repository.inserted_at, "%Y-%m-%d")}
            </p>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp load_repositories(socket) do
    case Repositories.list_repositories(%{}, socket.assigns.execution_context) do
      {:ok, repositories} -> repositories
      {:error, _reason} -> socket.assigns.repositories
    end
  end
end
