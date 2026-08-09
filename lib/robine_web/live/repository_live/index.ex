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
       discovery_provider: :github,
       discovery_state: :not_run
     )}
  end

  @impl true
  def handle_event("discover", _params, socket) do
    case Repositories.discover_github_repositories(%{}, socket.assigns.execution_context) do
      {:ok, repositories} ->
        {:noreply,
         assign(socket,
           available_repositories: repositories,
           discovery_provider: :github,
           discovery_state: :ready
         )}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only administrators can connect repositories.")}

      {:error, _reason} ->
        {:noreply, assign(socket, available_repositories: [], discovery_state: :error)}
    end
  end

  def handle_event("discover-provider", %{"provider" => provider_name}, socket) do
    with {:ok, provider} <- provider(provider_name),
         {:ok, repositories} <-
           Repositories.discover_source_control_repositories(
             %{provider: provider},
             socket.assigns.execution_context
           ) do
      {:noreply,
       assign(socket,
         available_repositories: repositories,
         discovery_provider: provider,
         discovery_state: :ready
       )}
    else
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

  def handle_event("trust-provider", params, socket) do
    input = %{
      provider: params["provider"],
      provider_instance: params["provider_instance"],
      provider_id: params["provider_id"],
      installation_id: params["installation_id"],
      full_name: params["full_name"]
    }

    case Repositories.trust_source_control_repository(input, socket.assigns.execution_context) do
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

      {:error, :repository_not_granted_to_source_control} ->
        {:noreply,
         put_flash(socket, :error, "The provider no longer grants access to that repository.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "The repository could not be trusted.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header class="border-b border-base-300/70 pb-8">
          <div class="mb-4 flex items-center gap-2 text-xs font-bold uppercase tracking-[0.18em] text-primary">
            <span class="size-1.5 rounded-full bg-primary"></span> Source control
          </div><h1 class="text-4xl font-bold sm:text-5xl">
            Repositories
          </h1><p class="mt-2 text-base-content/60">
            Only repositories explicitly verified against a configured provider execute workflows.
          </p>
        </header>
        <section
          :if={@current_actor.role == :administrator}
          class="surface-panel rounded-2xl p-6 sm:p-8"
          aria-labelledby="github-repository-selection"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 id="github-repository-selection" class="text-xl font-semibold">
                Source-control repositories
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                Discover live provider access, then explicitly trust only repositories that may run CI.
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
            <button
              id="discover-gitlab-repositories"
              phx-click="discover-provider"
              phx-value-provider="gitlab"
              phx-disable-with="Refreshing…"
              class="btn"
            >Discover GitLab</button>
            <button
              id="discover-forgejo-repositories"
              phx-click="discover-provider"
              phx-value-provider="forgejo"
              phx-disable-with="Refreshing…"
              class="btn"
            >Discover Forgejo</button>
          </div>
          <p :if={@discovery_state == :not_run} class="mt-5 text-sm text-base-content/60">
            No provider access has been queried in this browser session.
          </p>
          <.ui_state
            :if={@discovery_state == :error}
            kind={:degraded}
            title={"#{provider_label(@discovery_provider)} repositories are unavailable"}
            class="mt-5"
          >
            Check {provider_label(@discovery_provider)} credentials and connectivity, then try again.
            Trusted repositories remain active.
          </.ui_state>
          <.ui_state
            :if={@discovery_state == :ready and @available_repositories == []}
            kind={:empty}
            title={"No repository is available from #{provider_label(@discovery_provider)}"}
            class="mt-5 p-6"
          >
            Update repository access in {provider_label(@discovery_provider)}, then refresh.
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
                  {provider_label(@discovery_provider)} · Instance {Map.get(
                    repository,
                    :provider_instance,
                    "default"
                  )}{discovery_installation(@discovery_provider, repository)} · {if repository.private,
                    do: "Private",
                    else: "Public"}
                </p>
              </div>
              <button
                phx-click={if @discovery_provider == :github, do: "trust", else: "trust-provider"}
                phx-disable-with="Verifying…"
                phx-value-provider={@discovery_provider}
                phx-value-provider_instance={Map.get(repository, :provider_instance, "default")}
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
          Configure a source-control provider, discover its repositories, then explicitly trust one.
        </.ui_state>
        <div :if={@repositories != []} class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
          <article
            :for={repository <- @repositories}
            id={"repository-#{repository.id}"}
            class="surface-panel group rounded-2xl p-6 transition-all duration-200 hover:-translate-y-0.5 hover:border-primary/30"
          >
            <div class="flex items-start justify-between gap-4">
              <div>
                <p class="text-sm text-base-content/55">
                  {provider_label(repository.provider)} · Instance {repository.provider_instance}
                </p><.link
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

  defp provider("github"), do: {:ok, :github}
  defp provider("gitlab"), do: {:ok, :gitlab}
  defp provider("forgejo"), do: {:ok, :forgejo}
  defp provider(_provider), do: {:error, :invalid_source_control_provider}

  defp provider_label(:github), do: "GitHub"
  defp provider_label(:gitlab), do: "GitLab"
  defp provider_label(:forgejo), do: "Forgejo"

  defp discovery_installation(:github, repository),
    do: " · Installation #{repository.installation_id}"

  defp discovery_installation(_provider, _repository), do: ""
end
