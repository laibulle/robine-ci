defmodule RobineWeb.AdminLive.ApiTokens do
  use RobineWeb, :live_view

  alias Robine.Identities

  @default_expiration_days 90

  @impl true
  def mount(_params, _session, socket) do
    with {:ok, tokens} <-
           Identities.list_api_tokens(%{}, socket.assigns.execution_context) do
      {:ok,
       socket
       |> assign(
         token_count: length(tokens),
         token_form: token_form(),
         form_error: nil,
         revealed_token: nil
       )
       |> stream(:api_tokens, tokens)}
    else
      _reason ->
        {:ok,
         socket
         |> put_flash(:error, "API tokens could not be loaded.")
         |> push_navigate(to: ~p"/admin")}
    end
  end

  @impl true
  def handle_event("validate-token", %{"api_token" => params}, socket) do
    {:noreply,
     assign(socket,
       token_form: to_form(params, as: :api_token),
       form_error: nil
     )}
  end

  def handle_event("create-token", %{"api_token" => params}, socket) do
    with {:ok, days} <- expiration_days(params),
         {:ok, result} <-
           Identities.create_api_token(
             %{
               name: Map.get(params, "name"),
               permissions: ["artifacts:write"],
               expires_in_days: days
             },
             socket.assigns.execution_context
           ) do
      {:noreply,
       socket
       |> stream_insert(:api_tokens, result.credential, at: 0)
       |> assign(
         token_count: socket.assigns.token_count + 1,
         token_form: token_form(),
         form_error: nil,
         revealed_token: result.token
       )
       |> put_flash(:info, "API token created. Copy it before leaving this page.")}
    else
      {:error, {:invalid_api_token, :name}} ->
        {:noreply, assign(socket, :form_error, "Use a name between 1 and 64 characters.")}

      {:error, {:invalid_api_token, :expiration}} ->
        {:noreply, assign(socket, :form_error, "Expiration must be between 1 and 365 days.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You cannot create API tokens.")}

      _error ->
        {:noreply, assign(socket, :form_error, "The API token could not be created.")}
    end
  end

  def handle_event("revoke-token", %{"id" => token_id}, socket) do
    case Identities.revoke_api_token(
           %{token_id: token_id},
           socket.assigns.execution_context
         ) do
      :ok ->
        {:ok, tokens} =
          Identities.list_api_tokens(%{}, socket.assigns.execution_context)

        {:noreply,
         socket
         |> stream(:api_tokens, tokens, reset: true)
         |> assign(:revealed_token, nil)
         |> put_flash(:info, "API token revoked immediately.")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "You cannot revoke API tokens.")}

      _error ->
        {:noreply, put_flash(socket, :error, "The API token could not be revoked.")}
    end
  end

  def handle_event("dismiss-token", _params, socket) do
    {:noreply, assign(socket, :revealed_token, nil)}
  end

  defp expiration_days(%{"expires_in_days" => value}) do
    case Integer.parse(value) do
      {days, ""} when days in 1..365 -> {:ok, days}
      _invalid -> {:error, {:invalid_api_token, :expiration}}
    end
  end

  defp expiration_days(_params), do: {:error, {:invalid_api_token, :expiration}}

  defp token_form do
    to_form(
      %{"name" => "Local release upload", "expires_in_days" => "#{@default_expiration_days}"},
      as: :api_token
    )
  end

  defp status(token, now) do
    cond do
      match?(%DateTime{}, token.revoked_at) -> :revoked
      DateTime.compare(token.expires_at, now) != :gt -> :expired
      true -> :active
    end
  end

  defp status_label(:active), do: "Active"
  defp status_label(:expired), do: "Expired"
  defp status_label(:revoked), do: "Revoked"
  defp date_label(nil), do: "Never"
  defp date_label(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :now, DateTime.utc_now())

    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor} nav_section={:admin}>
      <section class="space-y-8">
        <.page_header
          eyebrow="Global automation"
          title="Artifact upload tokens"
          description="Issue a write-only credential for artifact uploads across every trusted repository."
          breadcrumbs={[
            %{label: "Administration", navigate: ~p"/admin"},
            %{label: "API tokens"}
          ]}
        >
          <:meta>
            <span id="api-token-count" class="badge badge-outline badge-sm">
              {@token_count} {if @token_count == 1, do: "token", else: "tokens"}
            </span>
          </:meta>
        </.page_header>

        <section
          :if={@revealed_token}
          id="api-token-one-time-reveal"
          class="rounded-2xl border border-warning/30 bg-warning/5 p-5 sm:p-6"
          role="status"
        >
          <div class="flex items-start justify-between gap-4">
            <div>
              <p class="font-bold text-warning">Copy this token now</p>
              <p class="mt-1 text-sm text-base-content/65">
                This is the only time Robine will show the secret. Store it in a keychain or secret manager.
              </p>
            </div>
            <button
              id="dismiss-api-token"
              type="button"
              phx-click="dismiss-token"
              class="btn btn-ghost btn-sm"
              aria-label="Hide API token"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <label
            for="new-api-token-value"
            class="mt-4 block text-xs font-bold uppercase tracking-wide"
          >
            Bearer token
          </label>
          <input
            id="new-api-token-value"
            type="text"
            value={@revealed_token}
            readonly
            autocomplete="off"
            spellcheck="false"
            class="input input-bordered mt-2 w-full font-mono text-xs"
          />
        </section>

        <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_24rem]">
          <section aria-labelledby="token-list-title">
            <div class="border-b border-base-300/70 pb-4">
              <p class="text-[0.68rem] font-bold uppercase tracking-[0.16em] text-primary">
                Instance global
              </p>
              <h2 id="token-list-title" class="mt-1 text-2xl font-bold">Credentials</h2>
            </div>

            <div id="api-tokens" phx-update="stream" class="mt-4 grid gap-3">
              <div id="api-tokens-empty" class="hidden only:block">
                <.ui_state kind={:empty} title="No API token yet" class="p-10">
                  <p>Create a short-lived credential for your local artifact upload automation.</p>
                </.ui_state>
              </div>

              <article
                :for={{dom_id, token} <- @streams.api_tokens}
                id={dom_id}
                class="surface-panel rounded-2xl p-5"
              >
                <div class="flex flex-wrap items-start justify-between gap-4">
                  <div>
                    <div class="flex flex-wrap items-center gap-2">
                      <span class={[
                        "badge badge-sm",
                        status(token, @now) == :active && "badge-success",
                        status(token, @now) != :active && "badge-ghost"
                      ]}>
                        {status_label(status(token, @now))}
                      </span>
                      <code class="text-xs text-base-content/50">{token.token_prefix}</code>
                    </div>
                    <h3 class="mt-3 text-lg font-bold">{token.name}</h3>
                    <p class="mt-1 text-xs text-base-content/50">
                      Created {date_label(token.inserted_at)} · expires {date_label(token.expires_at)}
                    </p>
                    <p class="mt-1 text-xs text-base-content/50">
                      Last used: {date_label(token.last_used_at)}
                    </p>
                  </div>
                  <button
                    :if={status(token, @now) == :active}
                    id={"revoke-api-token-#{token.id}"}
                    type="button"
                    phx-click="revoke-token"
                    phx-value-id={token.id}
                    data-confirm="Revoke this token immediately? Existing automation will stop working."
                    class="btn btn-error btn-outline btn-sm"
                  >
                    <.icon name="hero-no-symbol" class="size-4" /> Revoke
                  </button>
                </div>
                <div class="mt-4 rounded-xl bg-base-200/70 p-3">
                  <p class="text-[0.65rem] font-bold uppercase tracking-wide text-base-content/40">
                    Permission
                  </p>
                  <code class="mt-1 block text-xs">artifacts:write</code>
                  <p class="mt-1 text-xs text-base-content/50">
                    Upload only. No artifact reads, pipeline runs, secrets, tokens, or deployments.
                  </p>
                </div>
              </article>
            </div>
          </section>

          <aside class="space-y-4 xl:sticky xl:top-6 xl:self-start">
            <section class="surface-panel overflow-hidden rounded-2xl">
              <div class="border-b border-base-300/70 bg-base-200/60 p-5">
                <h2 class="font-bold">Create an upload token</h2>
                <p class="mt-1 text-xs text-base-content/50">
                  Every trusted repository · one permission
                </p>
              </div>
              <.form
                for={@token_form}
                id="api-token-form"
                phx-change="validate-token"
                phx-submit="create-token"
                class="space-y-5 p-5"
              >
                <.input
                  field={@token_form[:name]}
                  type="text"
                  label="Token name"
                  maxlength="64"
                  autocomplete="off"
                />
                <.input
                  field={@token_form[:expires_in_days]}
                  type="select"
                  label="Expiration"
                  options={[
                    {"7 days", "7"},
                    {"30 days", "30"},
                    {"90 days", "90"},
                    {"1 year", "365"}
                  ]}
                />
                <div class="rounded-xl border border-primary/20 bg-primary/5 p-4 text-sm">
                  <p class="font-bold">artifacts:write</p>
                  <p class="mt-1 text-xs text-base-content/60">
                    Can upload manual artifacts to any trusted repository in this Robine instance.
                  </p>
                </div>
                <p :if={@form_error} id="api-token-form-error" class="text-sm text-error" role="alert">
                  {@form_error}
                </p>
                <button
                  id="create-api-token"
                  type="submit"
                  class="btn btn-primary w-full"
                  phx-disable-with="Creating…"
                >
                  <.icon name="hero-key" class="size-4" /> Create token
                </button>
              </.form>
            </section>

            <section class="rounded-2xl border border-warning/20 bg-warning/5 p-5 text-sm">
              <div class="flex gap-3">
                <.icon name="hero-shield-exclamation" class="mt-0.5 size-5 shrink-0 text-warning" />
                <div>
                  <p class="font-bold">Treat it like a password</p>
                  <p class="mt-1 text-base-content/65">
                    Send it only as an Authorization Bearer header over TLS. Revoke it immediately if exposed.
                  </p>
                </div>
              </div>
            </section>
          </aside>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
