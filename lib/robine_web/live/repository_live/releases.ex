defmodule RobineWeb.RepositoryLive.Releases do
  use RobineWeb, :live_view
  alias Robine.{Publications, Repositories}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, repositories} <-
           Repositories.list_repositories(%{}, socket.assigns.execution_context),
         repository when not is_nil(repository) <- Enum.find(repositories, &(&1.id == id)),
         {:ok, overview} <-
           Publications.get_repository_overview(
             %{repository_id: id},
             socket.assigns.execution_context
           ) do
      {:ok,
       socket
       |> assign(
         repository: repository,
         policy: overview.policy,
         publication_count: length(overview.publications),
         policy_form: policy_form(overview.policy, repository),
         policy_error: nil
       )
       |> stream(:publications, overview.publications)}
    else
      _reason ->
        {:ok,
         socket
         |> put_flash(:error, "Repository releases could not be loaded.")
         |> push_navigate(to: ~p"/repositories")}
    end
  end

  @impl true
  def handle_event("save-policy", %{"policy" => params}, socket) do
    input = %{
      repository_id: socket.assigns.repository.id,
      enabled: Map.get(params, "enabled") in ["true", "on", "1"],
      public_slug: Map.get(params, "public_slug", "")
    }

    case Publications.configure_repository(input, socket.assigns.execution_context) do
      {:ok, policy} ->
        {:noreply,
         socket
         |> assign(
           policy: policy,
           policy_form: policy_form(policy, socket.assigns.repository),
           policy_error: nil
         )
         |> put_flash(:info, policy_flash(policy))}

      {:error, {:invalid_publication_policy, :public_slug}} ->
        {:noreply,
         assign(socket,
           policy_form: to_form(params, as: :policy),
           policy_error: "Use 3–63 lowercase letters, numbers, or internal hyphens."
         )}

      {:error, :forbidden} ->
        {:noreply,
         put_flash(socket, :error, "Only administrators can change publication policy.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(policy_form: to_form(params, as: :policy))
         |> put_flash(:error, "Publication settings could not be saved.")}
    end
  end

  defp policy_form(nil, repository) do
    to_form(%{"enabled" => false, "public_slug" => default_slug(repository)}, as: :policy)
  end

  defp policy_form(policy, _repository) do
    to_form(
      %{"enabled" => policy.enabled, "public_slug" => policy.public_slug},
      as: :policy
    )
  end

  defp default_slug(repository) do
    repository.name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
    |> then(fn
      slug when byte_size(slug) in 3..63 -> slug
      _slug -> "public-release"
    end)
  end

  defp policy_flash(%{enabled: true}),
    do: "Public release publication is enabled for successful version tags."

  defp policy_flash(%{enabled: false}),
    do: "New public release publication is disabled. Existing releases are unchanged."

  defp status_class(:published), do: "badge-success"
  defp status_class(:failed), do: "badge-error"
  defp status_class(:withdrawn), do: "badge-neutral"
  defp status_class(_status), do: "badge-warning"

  defp byte_size_label(size) when size < 1_024, do: "#{size} B"
  defp byte_size_label(size) when size < 1_048_576, do: "#{Float.round(size / 1_024, 1)} KiB"

  defp byte_size_label(size),
    do: "#{Float.round(size / 1_048_576, 1)} MiB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:repositories}>
      <section class="space-y-8">
        <.page_header
          eyebrow="Deliberately public"
          title="Public releases"
          description="Publish selected versioned binaries without exposing source, logs, caches, or ordinary CI artifacts."
          breadcrumbs={[
            %{label: "Repositories", navigate: ~p"/repositories"},
            %{label: @repository.full_name, navigate: ~p"/repositories/#{@repository.id}"},
            %{label: "Public releases"}
          ]}
        >
          <:meta>
            <div class="flex flex-wrap items-center gap-2">
              <span class={[
                "badge badge-sm",
                @policy && @policy.enabled && "badge-success",
                (!@policy || !@policy.enabled) && "badge-ghost"
              ]}>
                {if @policy && @policy.enabled, do: "Publishing enabled", else: "Publishing disabled"}
              </span>
              <span id="release-count" class="badge badge-outline badge-sm">
                {@publication_count} {if @publication_count == 1, do: "release", else: "releases"}
              </span>
            </div>
          </:meta>
        </.page_header>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_22rem]">
          <section aria-labelledby="release-list-title">
            <div class="flex flex-wrap items-end justify-between gap-3 border-b border-base-300/70 pb-4">
              <div>
                <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-primary">
                  Immutable downloads
                </p>
                <h2 id="release-list-title" class="mt-1 text-2xl font-bold">Release history</h2>
              </div>
              <div :if={@policy} class="text-right text-xs text-base-content/50">
                Public path
                <code id="public-release-prefix" class="mt-1 block rounded-lg bg-base-200 px-2 py-1">
                  /downloads/{@policy.public_slug}/…
                </code>
              </div>
            </div>

            <div id="publications" phx-update="stream" class="mt-4 grid gap-3">
              <div id="publications-empty" class="hidden only:block">
                <.ui_state kind={:empty} title="No public release yet" class="p-10">
                  <p>
                    Once enabled, a successful authenticated <code>vMAJOR.MINOR.PATCH</code> pipeline
                    can publish files staged with <code>publications/stage</code>.
                  </p>
                </.ui_state>
              </div>

              <article
                :for={{dom_id, release} <- @streams.publications}
                id={dom_id}
                class="surface-panel group rounded-2xl p-5 transition hover:border-primary/35"
              >
                <div class="flex flex-wrap items-start justify-between gap-4">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class={["badge badge-sm capitalize", status_class(release.status)]}>
                        {release.status}
                      </span>
                      <span class="font-mono text-xs font-bold text-primary">{release.release}</span>
                    </div>
                    <h3 class="mt-3 truncate text-lg font-bold">{release.filename}</h3>
                    <p class="mt-1 text-xs text-base-content/50">
                      {byte_size_label(release.size)} · {release.content_type}
                    </p>
                  </div>
                  <div
                    :if={release.status == :published && release.public_url}
                    class="flex flex-wrap gap-2"
                  >
                    <a href={release.public_url} class="btn btn-primary btn-sm" download>
                      <.icon name="hero-arrow-down-tray" class="size-4" /> Versioned
                    </a>
                    <a
                      :if={@policy && @policy.enabled}
                      id={"latest-release-#{release.id}"}
                      href={~p"/downloads/#{@policy.public_slug}/latest/#{release.filename}"}
                      class="btn btn-outline btn-sm"
                    >
                      <.icon name="hero-arrow-path" class="size-4" /> Latest
                    </a>
                  </div>
                </div>
                <dl class="mt-5 grid gap-3 rounded-xl bg-base-200/70 p-4 text-xs sm:grid-cols-2">
                  <div>
                    <dt class="font-bold uppercase tracking-wide text-base-content/40">SHA-256</dt>
                    <dd class="mt-1 truncate font-mono" title={release.digest}>{release.digest}</dd>
                  </div>
                  <div>
                    <dt class="font-bold uppercase tracking-wide text-base-content/40">Source</dt>
                    <dd class="mt-1 font-mono">
                      {release.source_tag} · {String.slice(release.source_commit, 0, 8)}
                    </dd>
                  </div>
                </dl>
              </article>
            </div>
          </section>

          <aside
            class="space-y-4 xl:sticky xl:top-6 xl:self-start"
            aria-labelledby="release-policy-title"
          >
            <section class="surface-panel overflow-hidden rounded-2xl">
              <div class="border-b border-base-300/70 bg-base-200/60 p-5">
                <div class="flex items-center gap-3">
                  <span class="grid size-10 place-items-center rounded-xl bg-primary/10 text-primary">
                    <.icon name="hero-globe-alt" class="size-5" />
                  </span>
                  <div>
                    <h2 id="release-policy-title" class="font-bold">Publication policy</h2>
                    <p class="text-xs text-base-content/50">Repository visibility is independent.</p>
                  </div>
                </div>
              </div>

              <.form
                :if={@current_actor.role == :administrator}
                for={@policy_form}
                id="publication-policy-form"
                phx-submit="save-policy"
                class="space-y-5 p-5"
              >
                <.input
                  field={@policy_form[:enabled]}
                  type="checkbox"
                  label="Allow public releases"
                />
                <.input
                  field={@policy_form[:public_slug]}
                  label="Public project slug"
                  required
                  minlength="3"
                  maxlength="63"
                  pattern="[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])?"
                  aria-describedby={@policy_error && "public-slug-error"}
                />
                <p :if={@policy_error} id="public-slug-error" class="text-sm text-error" role="alert">
                  {@policy_error}
                </p>
                <div class="alert alert-warning items-start text-xs">
                  <.icon name="hero-shield-exclamation" class="mt-0.5 size-4 shrink-0" />
                  <span>
                    Anyone will be able to download published files. Source code and CI data remain private.
                  </span>
                </div>
                <button
                  id="save-publication-policy"
                  class="btn btn-primary w-full"
                  phx-disable-with="Saving…"
                  data-confirm="Apply this public release policy? Published files can be copied and redistributed by anyone."
                >Save policy</button>
              </.form>

              <div
                :if={@current_actor.role != :administrator}
                class="p-5 text-sm text-base-content/60"
              >
                <p>Only an administrator can change this declassification policy.</p>
                <dl :if={@policy} class="mt-4 space-y-2 rounded-xl bg-base-200 p-4 text-xs">
                  <div class="flex justify-between gap-3">
                    <dt>Status</dt>
                    <dd class="font-bold">{if @policy.enabled, do: "Enabled", else: "Disabled"}</dd>
                  </div>
                  <div class="flex justify-between gap-3">
                    <dt>Public slug</dt>
                    <dd class="font-mono">{@policy.public_slug}</dd>
                  </div>
                </dl>
              </div>
            </section>

            <section class="rounded-2xl border border-base-300/70 p-5 text-sm">
              <h2 class="font-bold">What stays private</h2>
              <ul class="mt-3 space-y-2 text-base-content/60">
                <li class="flex gap-2">
                  <.icon name="hero-lock-closed" class="mt-0.5 size-4" />Source repository
                </li>
                <li class="flex gap-2">
                  <.icon name="hero-lock-closed" class="mt-0.5 size-4" />Logs and ordinary artifacts
                </li>
                <li class="flex gap-2">
                  <.icon name="hero-lock-closed" class="mt-0.5 size-4" />Caches and bucket inventory
                </li>
              </ul>
            </section>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
