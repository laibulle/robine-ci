defmodule RobineWeb.RepositoryLive.Index do
  use RobineWeb, :live_view
  alias Robine.Repositories

  @impl true
  def mount(_params, _session, socket) do
    repositories =
      case Repositories.list_repositories(%{}, socket.assigns.execution_context) do
        {:ok, values} -> values
        {:error, _reason} -> []
      end

    {:ok, assign(socket, repositories: repositories)}
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
        <div
          :if={@repositories == []}
          class="rounded-3xl border border-dashed border-base-300 p-12 text-center"
        >
          <h2 class="text-xl font-semibold">No trusted repository</h2><p class="mt-2 text-base-content/60">
            Install the GitHub App, then register the selected repository using the setup instructions.
          </p>
        </div>
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
end
