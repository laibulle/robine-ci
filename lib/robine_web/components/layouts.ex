defmodule RobineWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use RobineWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :current_actor, :map, default: nil
  attr :nav_section, :atom, default: nil
  attr :shell, :boolean, default: true, doc: "renders the authenticated application chrome"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :build_info, Robine.BuildInfo.current(%{}))

    ~H"""
    <div
      :if={@shell}
      class="app-shell h-dvh overflow-hidden lg:grid lg:grid-cols-[15rem_minmax(0,1fr)]"
    >
      <aside class="app-sidebar sticky top-0 z-30 hidden h-dvh flex-col px-3 py-4 lg:flex">
        <nav class="flex h-full flex-col" aria-label="Primary navigation">
          <a
            href={if @current_actor, do: ~p"/pipelines", else: ~p"/"}
            class="flex items-center gap-3 px-2 py-2 font-bold tracking-tight"
          >
            <.brand_mark class="size-9 shrink-0" />
            <span class="leading-none">Robine <span class="font-medium text-base-content/35">CI</span></span>
          </a>
          <div :if={@current_actor} class="mt-9 space-y-1">
            <p class="mb-3 px-3 text-[0.65rem] font-bold uppercase tracking-[0.18em] text-base-content/35">
              Workspace
            </p>
            <.link
              navigate={~p"/pipelines"}
              class={["app-nav-link", @nav_section == :pipelines && "app-nav-link-active"]}
              aria-current={@nav_section == :pipelines && "page"}
            ><.icon
              name="hero-bolt"
              class="size-4"
            /> Pipelines</.link>
            <.link
              navigate={~p"/repositories"}
              class={["app-nav-link", @nav_section == :repositories && "app-nav-link-active"]}
              aria-current={@nav_section == :repositories && "page"}
            ><.icon
              name="hero-code-bracket-square"
              class="size-4"
            /> Repositories</.link>
            <.link
              :if={@current_actor.role == :administrator}
              navigate={~p"/admin"}
              class={["app-nav-link", @nav_section == :admin && "app-nav-link-active"]}
              aria-current={@nav_section == :admin && "page"}
            ><.icon name="hero-adjustments-horizontal" class="size-4" /> Administration</.link>
          </div>
          <div class="mt-auto space-y-3 pb-1">
            <.link :if={is_nil(@current_actor)} href={~p"/sign-in"} class="btn btn-primary w-full">Sign in</.link>
            <footer :if={@current_actor} id="application-build-footer" class="px-1">
              <.link
                navigate={~p"/build-information"}
                class="group flex items-center gap-2 rounded-lg px-2 py-1.5 text-[0.65rem] text-base-content/35 transition hover:bg-base-200/70 hover:text-base-content focus-visible:text-base-content"
                aria-label="Open build information"
              >
                <.icon name="hero-code-bracket" class="size-3.5 shrink-0" />
                <span class="min-w-0 truncate">
                  Robine {@build_info.version} · {@build_info.display_ref}@{@build_info.short_commit}
                </span>
                <.icon
                  name="hero-chevron-right"
                  class="ml-auto size-3 shrink-0 opacity-0 transition group-hover:opacity-100"
                />
              </.link>
            </footer>
            <div :if={@current_actor} class="rounded-xl border border-base-300/70 bg-base-200/45 p-3">
              <div class="flex items-center gap-2.5">
                <span class="grid size-7 shrink-0 place-items-center rounded-full bg-primary/15 text-[0.65rem] font-black uppercase text-primary">{String.first(
                  @current_actor.email
                )}</span>
                <div class="min-w-0">
                  <p class="truncate text-xs font-semibold">{@current_actor.email}</p><p class="mt-0.5 text-[0.62rem] capitalize text-base-content/40">
                    {@current_actor.role}
                  </p>
                </div>
              </div>
              <div class="mt-3 flex items-center justify-between">
                <.theme_toggle />
                <.link
                  href={~p"/sign-out"}
                  method="delete"
                  class="btn btn-ghost btn-xs"
                  aria-label="Sign out"
                ><.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /></.link>
              </div>
            </div>
          </div>
        </nav>
      </aside>

      <div class="app-content h-dvh min-w-0 overflow-y-auto overscroll-y-none">
        <header class="sticky top-0 z-30 border-b border-base-300/70 bg-base-100/85 backdrop-blur-xl lg:hidden">
          <div class="flex h-16 items-center justify-between px-4">
            <a
              href={if @current_actor, do: ~p"/pipelines", else: ~p"/"}
              class="flex items-center gap-2 font-bold"
            ><.brand_mark class="size-8 shrink-0" /> Robine CI</a>
            <div class="flex items-center gap-1">
              <.link
                :if={@current_actor}
                navigate={~p"/build-information"}
                class="btn btn-ghost btn-sm btn-square"
                aria-label="About this Robine build"
              ><.icon name="hero-information-circle" class="size-4" /></.link>
              <.theme_toggle />
              <.link :if={is_nil(@current_actor)} href={~p"/sign-in"} class="btn btn-primary btn-sm">Sign in</.link>
            </div>
          </div>
        </header>

        <div id="page-loading-status" class="sr-only" aria-live="polite"></div>
        <main id="main-content" class="px-4 pb-28 pt-8 sm:px-8 sm:py-12 xl:px-14">
          <div class="mx-auto max-w-6xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <nav
        :if={@current_actor}
        class="app-mobile-nav fixed inset-x-3 bottom-3 z-40 grid grid-cols-3 rounded-2xl border border-base-300/80 bg-base-100/95 p-1.5 backdrop-blur-xl lg:hidden"
        aria-label="Mobile navigation"
      >
        <.link
          navigate={~p"/pipelines"}
          class={[
            "mobile-nav-link",
            @nav_section == :pipelines && "mobile-nav-link-active"
          ]}
          aria-current={@nav_section == :pipelines && "page"}
        ><.icon name="hero-bolt" class="size-5" />Pipelines</.link>
        <.link
          navigate={~p"/repositories"}
          class={[
            "mobile-nav-link",
            @nav_section == :repositories && "mobile-nav-link-active"
          ]}
          aria-current={@nav_section == :repositories && "page"}
        ><.icon name="hero-code-bracket-square" class="size-5" />Repositories</.link>
        <.link
          :if={@current_actor.role == :administrator}
          navigate={~p"/admin"}
          class={["mobile-nav-link", @nav_section == :admin && "mobile-nav-link-active"]}
          aria-current={@nav_section == :admin && "page"}
        ><.icon name="hero-adjustments-horizontal" class="size-5" />Admin</.link>
        <.link
          :if={@current_actor.role != :administrator}
          href={~p"/sign-out"}
          method="delete"
          class="mobile-nav-link"
        ><.icon name="hero-arrow-right-start-on-rectangle" class="size-5" />Sign out</.link>
      </nav>
    </div>

    <main :if={!@shell} id="main-content" class="min-h-screen px-4 py-6 sm:px-6 sm:py-8 lg:px-8">
      {render_slot(@inner_block)}
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc "Renders the Robine monogram with the variant matching the active product theme."
  attr :class, :string, default: nil

  def brand_mark(assigns) do
    ~H"""
    <span class={[@class, "inline-block"]} aria-hidden="true">
      <img
        src={~p"/images/brand/robine-mark.png"}
        alt=""
        class="size-full object-contain dark:hidden"
      />
      <img
        src={~p"/images/brand/robine-mark-dark.png"}
        alt=""
        class="hidden size-full object-contain dark:block"
      />
    </span>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative flex flex-row items-center rounded-full border border-base-300 bg-base-300/70 p-0.5">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="relative z-10 flex w-1/3 cursor-pointer p-1.5"
        type="button"
        aria-label="Use system theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative z-10 flex w-1/3 cursor-pointer p-1.5"
        type="button"
        aria-label="Use light theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="relative z-10 flex w-1/3 cursor-pointer p-1.5"
        type="button"
        aria-label="Use dark theme"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
