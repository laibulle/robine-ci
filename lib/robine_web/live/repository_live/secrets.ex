defmodule RobineWeb.RepositoryLive.Secrets do
  use RobineWeb, :live_view
  alias Robine.{Repositories, Secrets}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, repositories} <-
           Repositories.list_repositories(%{}, socket.assigns.execution_context),
         repository when not is_nil(repository) <- Enum.find(repositories, &(&1.id == id)) do
      {:ok,
       socket
       |> assign(repository: repository, form: to_form(%{"name" => "", "value" => ""}))
       |> load_secrets()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Repository not found.")
         |> push_navigate(to: ~p"/repositories")}
    end
  end

  @impl true
  def handle_event("save", %{"name" => name, "value" => value}, socket) do
    case Secrets.store_secret(
           %{
             name: name,
             value: value,
             scope: :repository,
             repository_id: socket.assigns.repository.id
           },
           socket.assigns.execution_context
         ) do
      {:ok, _metadata} ->
        {:noreply,
         socket
         |> put_flash(:info, "Secret stored. Its value cannot be read back.")
         |> assign(form: to_form(%{"name" => "", "value" => ""}))
         |> load_secrets()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Cannot store secret: #{inspect(reason)}")}
    end
  end

  defp load_secrets(socket) do
    case Secrets.list_secrets(
           %{repository_id: socket.assigns.repository.id},
           socket.assigns.execution_context
         ) do
      {:ok, secrets} -> assign(socket, secrets: secrets)
      {:error, _reason} -> assign(socket, secrets: [])
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="space-y-8">
        <header>
          <.link navigate={~p"/repositories/#{@repository.id}"} class="link text-sm">← {@repository.full_name}</.link><h1 class="mt-4 text-4xl font-bold">
            Secrets
          </h1><p class="mt-2 text-base-content/60">
            Values are encrypted, write-only, and exposed only to explicitly referencing jobs.
          </p>
        </header>
        <div class="grid gap-8 lg:grid-cols-2">
          <section class="rounded-3xl border border-base-300 bg-base-100 p-6">
            <h2 class="text-xl font-semibold">Store repository secret</h2><.form
              for={@form}
              id="secret-form"
              phx-submit="save"
              class="mt-6 space-y-5"
            >
              <.input
                field={@form[:name]}
                label="Name"
                placeholder="REGISTRY_TOKEN"
                required
                pattern="[A-Z_][A-Z0-9_]*"
              /><.input
                field={@form[:value]}
                type="password"
                label="Value"
                required
                minlength="8"
                autocomplete="off"
              /><.button class="btn btn-primary w-full" phx-disable-with="Encrypting…">Store secret</.button>
            </.form>
          </section><section>
            <h2 class="text-xl font-semibold">Available metadata</h2><div
              :if={@secrets == []}
              class="mt-4 rounded-2xl border border-dashed border-base-300 p-8 text-center text-base-content/60"
            >
              No secret is configured.
            </div><ul class="mt-4 space-y-3">
              <li :for={secret <- @secrets} class="rounded-2xl border border-base-300 p-5">
                <div class="flex justify-between">
                  <code class="font-semibold">{secret.name}</code><span class="badge">{secret.scope}</span>
                </div><p class="mt-2 text-xs text-base-content/55">
                  Updated {Calendar.strftime(secret.inserted_at, "%Y-%m-%d %H:%M UTC")}
                </p>
              </li>
            </ul>
          </section>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
