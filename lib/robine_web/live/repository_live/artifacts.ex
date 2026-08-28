defmodule RobineWeb.RepositoryLive.Artifacts do
  use RobineWeb, :live_view

  alias Robine.{Repositories, Storage}

  @retention_days 30
  @stream_chunk_bytes 1_000_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, repositories} <-
           Repositories.list_repositories(%{}, socket.assigns.execution_context),
         %{provider: :github} = repository <- Enum.find(repositories, &(&1.id == id)),
         {:ok, artifacts} <-
           Storage.list_repository_artifacts(
             %{repository_id: id},
             socket.assigns.execution_context
           ) do
      max_file_size = Application.fetch_env!(:robine, :storage_max_object_bytes)

      {:ok,
       socket
       |> assign(
         repository: repository,
         artifact_count: length(artifacts),
         upload_form: upload_form(@retention_days),
         upload_error: nil,
         last_upload: nil,
         max_file_size: max_file_size
       )
       |> allow_upload(:artifact,
         accept: :any,
         max_entries: 1,
         max_file_size: max_file_size
       )
       |> stream(:artifacts, artifacts)}
    else
      _reason ->
        {:ok,
         socket
         |> put_flash(:error, "Repository artifacts could not be loaded.")
         |> push_navigate(to: ~p"/repositories")}
    end
  end

  @impl true
  def handle_event("validate-upload", %{"artifact_upload" => params}, socket) do
    {:noreply,
     assign(socket,
       upload_form: to_form(params, as: :artifact_upload),
       upload_error: nil
     )}
  end

  def handle_event("upload-artifact", %{"artifact_upload" => params}, socket) do
    with {:ok, retention_days} <- retention_days(params),
         {[_entry], []} <- uploaded_entries(socket, :artifact),
         [{:ok, artifact}] <- consume(socket, retention_days) do
      {:noreply,
       socket
       |> stream_insert(:artifacts, artifact, at: 0)
       |> assign(
         artifact_count: socket.assigns.artifact_count + 1,
         upload_form: upload_form(retention_days),
         upload_error: nil,
         last_upload: artifact
       )
       |> put_flash(:info, "Artifact uploaded and verified with SHA-256.")}
    else
      {[], [_entry]} ->
        {:noreply, assign(socket, :upload_error, "Wait for the file transfer to finish.")}

      {:error, message} ->
        {:noreply, assign(socket, :upload_error, message)}

      [error] ->
        {:noreply, assign(socket, :upload_error, storage_error(error))}

      _error ->
        {:noreply, assign(socket, :upload_error, "Select one file to upload.")}
    end
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :artifact, ref)}
  end

  defp consume(socket, retention_days) do
    consume_uploaded_entries(socket, :artifact, fn %{path: path}, entry ->
      result =
        Storage.upload_manual_artifact(
          %{
            repository_id: socket.assigns.repository.id,
            name: entry.client_name,
            content_type: entry.client_type || "application/octet-stream",
            content_stream: File.stream!(path, @stream_chunk_bytes, []),
            retention_seconds: retention_days * 86_400
          },
          socket.assigns.execution_context
        )

      {:ok, result}
    end)
  end

  defp retention_days(%{"retention_days" => value}) do
    case Integer.parse(value) do
      {days, ""} when days in 1..365 -> {:ok, days}
      _invalid -> {:error, "Retention must be between 1 and 365 days."}
    end
  end

  defp retention_days(_params), do: {:error, "Select a retention period."}

  defp upload_form(days),
    do: to_form(%{"retention_days" => Integer.to_string(days)}, as: :artifact_upload)

  defp storage_error({:error, :forbidden}), do: "Only maintainers can upload artifacts."
  defp storage_error({:error, :object_too_large}), do: "The file exceeds the configured limit."

  defp storage_error({:error, {:quota_exceeded, _scope, _limit}}),
    do: "The configured storage quota is exhausted."

  defp storage_error({:error, {:invalid_artifact, :name}}),
    do: "Use a filename containing only letters, numbers, dots, underscores, and hyphens."

  defp storage_error(_error), do: "The artifact could not be stored. Try again."

  defp upload_error(:too_large), do: "The file exceeds the configured limit."
  defp upload_error(:too_many_files), do: "Upload one file at a time."
  defp upload_error(:not_accepted), do: "This file type is not accepted."
  defp upload_error(_reason), do: "The file could not be uploaded."

  defp byte_size_label(size) when size < 1_024, do: "#{size} B"
  defp byte_size_label(size) when size < 1_048_576, do: "#{Float.round(size / 1_024, 1)} KiB"

  defp byte_size_label(size) when size < 1_073_741_824,
    do: "#{Float.round(size / 1_048_576, 1)} MiB"

  defp byte_size_label(size), do: "#{Float.round(size / 1_073_741_824, 2)} GiB"

  defp date_label(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  defp uploader_label(artifact, current_actor) do
    if artifact.uploaded_by_id == current_actor.id,
      do: "You",
      else: "User #{String.slice(artifact.uploaded_by_id || "unknown", 0, 8)}"
  end

  defp source_label(%{source: :ci}), do: "CI"
  defp source_label(%{source: :manual}), do: "Manual"

  defp provenance_label(%{source: :ci, attempt_id: attempt_id}) do
    "Produced by CI attempt #{String.slice(attempt_id || "unknown", 0, 8)}"
  end

  defp provenance_label(%{source: :manual} = artifact, current_actor) do
    "Uploaded by #{uploader_label(artifact, current_actor)}"
  end

  defp provenance_label(%{source: :ci} = artifact, _current_actor),
    do: provenance_label(artifact)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:repositories}>
      <section class="space-y-8">
        <.page_header
          eyebrow="Repository storage"
          title="Private artifacts"
          description="Download retained CI outputs and keep locally built, signed, or notarized binaries beside them."
          breadcrumbs={[
            %{label: "Repositories", navigate: ~p"/repositories"},
            %{label: @repository.full_name, navigate: ~p"/repositories/#{@repository.id}"},
            %{label: "Artifacts"}
          ]}
        >
          <:meta>
            <span id="artifact-count" class="badge badge-outline badge-sm">
              {@artifact_count} {if @artifact_count == 1, do: "artifact", else: "artifacts"}
            </span>
          </:meta>
        </.page_header>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_24rem]">
          <section aria-labelledby="artifact-list-title">
            <div class="border-b border-base-300/70 pb-4">
              <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-primary">
                Digest verified
              </p>
              <h2 id="artifact-list-title" class="mt-1 text-2xl font-bold">Retained artifacts</h2>
            </div>

            <div id="repository-artifacts" phx-update="stream" class="mt-4 grid gap-3">
              <div id="repository-artifacts-empty" class="hidden only:block">
                <.ui_state kind={:empty} title="No retained artifact yet" class="p-10">
                  <p>Run a workflow that uploads an artifact or add a local binary from this page.</p>
                </.ui_state>
              </div>

              <article
                :for={{dom_id, artifact} <- @streams.artifacts}
                id={dom_id}
                class="surface-panel rounded-2xl p-5 transition hover:border-primary/35"
              >
                <div class="flex flex-wrap items-start justify-between gap-4">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <span class={[
                        "badge badge-sm",
                        artifact.source == :manual && "badge-primary",
                        artifact.source == :ci && "badge-secondary"
                      ]}>
                        {source_label(artifact)}
                      </span>
                      <span class="text-xs text-base-content/50">
                        {byte_size_label(artifact.size)} · {artifact.content_type}
                      </span>
                    </div>
                    <h3 class="mt-3 truncate text-lg font-bold" title={artifact.name}>
                      {artifact.name}
                    </h3>
                    <p class="mt-1 text-xs text-base-content/50">
                      {provenance_label(artifact, @current_actor)} on {date_label(artifact.created_at)} · expires {date_label(
                        artifact.expires_at
                      )}
                    </p>
                  </div>
                  <a
                    id={"download-artifact-#{artifact.id}"}
                    href={~p"/repositories/#{@repository.id}/artifacts/#{artifact.id}/download"}
                    class="btn btn-primary btn-sm"
                    download
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> Download
                  </a>
                </div>
                <div class="mt-4 rounded-xl bg-base-200/70 p-4">
                  <p class="text-[0.65rem] font-bold uppercase tracking-wide text-base-content/40">
                    SHA-256
                  </p>
                  <code class="mt-1 block break-all text-xs" title={artifact.digest}>
                    {artifact.digest}
                  </code>
                </div>
              </article>
            </div>
          </section>

          <aside class="space-y-4 xl:sticky xl:top-6 xl:self-start">
            <section
              :if={@current_actor.role in [:administrator, :maintainer]}
              id="manual-artifact-upload-panel"
              class="surface-panel overflow-hidden rounded-2xl"
              phx-drop-target={@uploads.artifact.ref}
            >
              <div class="border-b border-base-300/70 bg-base-200/60 p-5">
                <div class="flex items-center gap-3">
                  <span class="grid size-10 place-items-center rounded-xl bg-primary/10 text-primary">
                    <.icon name="hero-cloud-arrow-up" class="size-5" />
                  </span>
                  <div>
                    <h2 class="font-bold">Upload a binary</h2>
                    <p class="text-xs text-base-content/50">
                      Maximum {byte_size_label(@max_file_size)}
                    </p>
                  </div>
                </div>
              </div>

              <.form
                for={@upload_form}
                id="manual-artifact-form"
                phx-change="validate-upload"
                phx-submit="upload-artifact"
                class="space-y-5 p-5"
              >
                <label
                  for={@uploads.artifact.ref}
                  class="group grid cursor-pointer place-items-center rounded-2xl border border-dashed border-base-300 bg-base-200/40 px-5 py-8 text-center transition hover:border-primary hover:bg-primary/5"
                >
                  <.icon
                    name="hero-document-arrow-up"
                    class="size-8 text-primary transition group-hover:-translate-y-0.5"
                  />
                  <span class="mt-3 text-sm font-bold">Choose or drop one file</span>
                  <span class="mt-1 text-xs text-base-content/50">DMG, ZIP, archive, or binary</span>
                </label>
                <.live_file_input
                  upload={@uploads.artifact}
                  id="manual-artifact-file"
                  class="sr-only"
                />

                <div
                  :for={entry <- @uploads.artifact.entries}
                  id={"upload-entry-#{entry.ref}"}
                  class="rounded-xl bg-base-200 p-3"
                >
                  <div class="flex items-center justify-between gap-3 text-xs">
                    <span class="min-w-0 truncate font-bold">{entry.client_name}</span>
                    <button
                      type="button"
                      phx-click="cancel-upload"
                      phx-value-ref={entry.ref}
                      class="btn btn-ghost btn-xs"
                      aria-label={"Remove #{entry.client_name}"}
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                  <progress
                    class="progress progress-primary mt-2 w-full"
                    value={entry.progress}
                    max="100"
                  >
                    {entry.progress}%
                  </progress>
                  <p
                    :for={error <- upload_errors(@uploads.artifact, entry)}
                    class="mt-2 text-xs text-error"
                  >
                    {upload_error(error)}
                  </p>
                </div>

                <.input
                  field={@upload_form[:retention_days]}
                  type="select"
                  label="Retention"
                  options={[{"7 days", "7"}, {"30 days", "30"}, {"90 days", "90"}, {"1 year", "365"}]}
                />

                <p
                  :if={@upload_error}
                  id="manual-artifact-upload-error"
                  class="text-sm text-error"
                  role="alert"
                >
                  {@upload_error}
                </p>

                <button
                  id="upload-manual-artifact"
                  type="submit"
                  class="btn btn-primary w-full"
                  phx-disable-with="Verifying and storing…"
                >
                  <.icon name="hero-shield-check" class="size-4" /> Store immutable artifact
                </button>
              </.form>
            </section>

            <section class="rounded-2xl border border-info/20 bg-info/5 p-5 text-sm">
              <div class="flex gap-3">
                <.icon name="hero-information-circle" class="mt-0.5 size-5 shrink-0 text-info" />
                <div>
                  <p class="font-bold">Signing stays local</p>
                  <p class="mt-1 text-base-content/65">
                    Robine verifies the uploaded bytes and digest. It does not perform or validate Apple signing or notarization.
                  </p>
                </div>
              </div>
            </section>

            <section
              :if={@last_upload}
              id="last-manual-upload"
              class="rounded-2xl border border-success/25 bg-success/5 p-5 text-sm"
            >
              <p class="font-bold text-success">Upload complete</p>
              <p class="mt-1 break-all font-mono text-xs">{@last_upload.digest}</p>
            </section>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
