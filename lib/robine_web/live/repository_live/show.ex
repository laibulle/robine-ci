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
         workflows: workflows
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
