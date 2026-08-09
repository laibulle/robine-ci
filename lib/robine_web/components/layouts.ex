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

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="app-shell lg:grid lg:grid-cols-[16rem_minmax(0,1fr)]">
      <aside class="app-sidebar sticky top-0 z-30 hidden h-screen flex-col p-4 lg:flex">
        <nav class="flex h-full flex-col" aria-label="Primary navigation">
          <a
            href={if @current_actor, do: ~p"/pipelines", else: ~p"/"}
            class="flex items-center gap-3 px-2 py-3 font-bold tracking-tight"
          >
            <span class="grid size-10 place-items-center rounded-xl bg-primary text-lg text-primary-content shadow-lg shadow-primary/20">R</span>
            <span class="leading-none">Robine <span class="text-base-content/40">CI</span></span>
          </a>
          <div :if={@current_actor} class="mt-8 space-y-1">
            <p class="mb-3 px-3 text-[0.65rem] font-bold uppercase tracking-[0.18em] text-base-content/35">
              Workspace
            </p>
            <.link navigate={~p"/pipelines"} class="app-nav-link"><.icon
              name="hero-bolt"
              class="size-4"
            /> Pipelines</.link>
            <.link navigate={~p"/repositories"} class="app-nav-link"><.icon
              name="hero-code-bracket-square"
              class="size-4"
            /> Repositories</.link>
            <.link
              :if={@current_actor.role == :administrator}
              navigate={~p"/admin"}
              class="app-nav-link"
            ><.icon name="hero-adjustments-horizontal" class="size-4" /> Administration</.link>
          </div>
          <div class="mt-auto space-y-3">
            <.link :if={is_nil(@current_actor)} href={~p"/sign-in"} class="btn btn-primary w-full">Sign in</.link>
            <div :if={@current_actor} class="rounded-2xl border border-base-300/70 bg-base-200/60 p-3">
              <p class="truncate text-xs font-semibold">{@current_actor.email}</p>
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

      <div class="min-w-0">
        <header class="sticky top-0 z-30 border-b border-base-300/80 bg-base-100/85 backdrop-blur-xl lg:hidden">
          <div class="flex h-16 items-center justify-between px-4">
            <a
              href={if @current_actor, do: ~p"/pipelines", else: ~p"/"}
              class="flex items-center gap-2 font-bold"
            ><span class="grid size-8 place-items-center rounded-lg bg-primary text-primary-content">R</span>
            Robine CI</a>
            <div class="flex items-center gap-1">
              <.link
                :if={@current_actor}
                navigate={~p"/pipelines"}
                class="btn btn-ghost btn-sm"
                aria-label="Pipelines"
              ><.icon name="hero-bolt" class="size-5" /></.link>
              <.link
                :if={@current_actor}
                navigate={~p"/repositories"}
                class="btn btn-ghost btn-sm"
                aria-label="Repositories"
              ><.icon name="hero-code-bracket-square" class="size-5" /></.link>
              <.theme_toggle />
              <.link :if={is_nil(@current_actor)} href={~p"/sign-in"} class="btn btn-primary btn-sm">Sign in</.link>
            </div>
          </div>
        </header>

        <div id="page-loading-status" class="sr-only" aria-live="polite"></div>
        <main id="main-content" class="px-4 py-8 sm:px-8 sm:py-12 xl:px-14">
          <div class="mx-auto max-w-7xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

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
