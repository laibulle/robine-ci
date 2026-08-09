defmodule RobineWeb.RepositoryLive.Show do
  use RobineWeb, :live_view
  alias Robine.{Pipelines, Repositories}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, repositories} <-
           Repositories.list_repositories(%{}, socket.assigns.execution_context),
         repository when not is_nil(repository) <- Enum.find(repositories, &(&1.id == id)),
         {:ok, pipelines} <-
           Pipelines.list_pipelines(%{limit: 100}, socket.assigns.execution_context) do
      repository_pipelines = Enum.filter(pipelines, &(&1.repository_id == id))

      workflows =
        repository_pipelines |> Enum.map(& &1.workflow_name) |> Enum.uniq() |> Enum.sort()

      {:ok,
       assign(socket,
         repository: repository,
         pipelines: repository_pipelines,
         workflows: workflows,
         github_preflight: :not_run
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Repository not found.")
         |> push_navigate(to: ~p"/repositories")}
    end
  end

  @impl true
  def handle_event("check-github-installation", _params, socket) do
    result =
      Repositories.check_github_installation(
        %{repository_id: socket.assigns.repository.id},
        socket.assigns.execution_context
      )

    {:noreply, assign(socket, github_preflight: result)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header>
          <.link navigate={~p"/repositories"} class="link text-sm">← Repositories</.link><div class="mt-4 flex flex-wrap items-center gap-3">
            <h1 class="text-4xl font-bold">{@repository.full_name}</h1><span class="badge badge-success">Trusted</span>
          </div><div :if={@current_actor.role in [:administrator, :maintainer]} class="mt-5">
            <.link
              navigate={~p"/repositories/#{@repository.id}/secrets"}
              class="btn btn-outline btn-sm"
            >Manage secrets</.link>
          </div>
        </header>
        <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 class="text-xl font-semibold">GitHub installation</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Required repository permissions: Metadata read, Contents read, Checks write.
              </p>
            </div>
            <button
              :if={@current_actor.role in [:administrator, :maintainer]}
              id="check-github-installation"
              phx-click="check-github-installation"
              phx-disable-with="Checking…"
              class="btn btn-outline btn-sm"
            >Check permissions</button>
          </div>
          <p :if={@github_preflight == :not_run} class="mt-4 text-sm text-base-content/60">
            Permission preflight has not run in this session.
          </p>
          <div
            :if={match?({:ok, %{status: :ok}}, @github_preflight)}
            class="alert alert-success mt-4"
            role="status"
          >
            The installation has every required least-privilege permission.
          </div>
          <div
            :if={match?({:ok, %{status: :degraded}}, @github_preflight)}
            class="alert alert-warning mt-4 block"
            role="alert"
          >
            <p class="font-semibold">Installation permissions need attention.</p>
            <ul class="mt-2 list-disc space-y-1 pl-5">
              <li :for={missing <- elem(@github_preflight, 1).missing}>
                {missing.corrective_action} Current value: <code>{missing.actual}</code>.
              </li>
            </ul>
          </div>
          <div
            :if={match?({:error, _reason}, @github_preflight)}
            class="alert alert-error mt-4"
            role="alert"
          >
            GitHub could not verify this installation. Check credentials, connectivity, and installation approval.
          </div>
        </section>
        <div class="grid gap-6 lg:grid-cols-2">
          <section>
            <h2 class="text-xl font-semibold">Workflows</h2><div
              :if={@workflows == []}
              class="mt-4 rounded-2xl border border-dashed border-base-300 p-8 text-center text-base-content/60"
            >
              No valid workflow has run yet.
            </div><ul :if={@workflows != []} class="mt-4 space-y-3">
              <li
                :for={workflow <- @workflows}
                class="rounded-2xl border border-base-300 p-5 font-semibold"
              >
                {workflow}
              </li>
            </ul>
          </section><section>
            <h2 class="text-xl font-semibold">Recent pipelines</h2><div
              :if={@pipelines == []}
              class="mt-4 rounded-2xl border border-dashed border-base-300 p-8 text-center text-base-content/60"
            >
              Waiting for a matching push or pull request.
            </div><ul class="mt-4 space-y-3">
              <li
                :for={pipeline <- Enum.take(@pipelines, 10)}
                class="rounded-2xl border border-base-300 p-5"
              >
                <div class="flex justify-between gap-4">
                  <.link
                    navigate={~p"/pipelines/#{pipeline.id}"}
                    class="font-semibold link link-hover"
                  >{pipeline.workflow_name}</.link><span class="badge">{pipeline.status}</span>
                </div><code class="mt-2 block text-xs">{String.slice(pipeline.commit_sha, 0, 12)}</code>
              </li>
            </ul>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
