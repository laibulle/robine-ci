defmodule RobineWeb.BuildInfoLive.Show do
  use RobineWeb, :live_view

  alias Robine.BuildInfo

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Build information", build_info: BuildInfo.current(%{}))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_actor={@current_actor}>
      <section class="mx-auto max-w-4xl space-y-7">
        <.page_header
          eyebrow="Support & provenance"
          title="Build information"
          description="Immutable provenance embedded when this Robine release was compiled. Include it when reporting a problem or verifying a deployment."
        />

        <.ui_state
          :if={!@build_info.release?}
          kind={:degraded}
          title="Development build"
        >
          This instance was not compiled inside a provenance-aware Robine CI job. The values below are explicit development placeholders.
        </.ui_state>

        <section
          class="surface-panel overflow-hidden rounded-2xl"
          aria-labelledby="release-identity-title"
        >
          <div class="border-b border-base-300/70 p-5 sm:p-6">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <p class="text-xs font-bold uppercase tracking-[0.14em] text-base-content/40">
                  Robine CI
                </p>
                <h2 id="release-identity-title" class="mt-1 text-2xl font-bold">
                  Version {@build_info.version}
                </h2>
              </div>
              <span class={["badge", @build_info.release? && "badge-success"]}>
                {if(@build_info.release?, do: "Release build", else: "Local build")}
              </span>
            </div>
          </div>
          <dl id="build-provenance" class="divide-y divide-base-300/70">
            <.build_field
              label="Source reference"
              value={@build_info.display_ref}
              detail={@build_info.ref_type}
            />
            <.build_field label="Commit SHA" value={@build_info.commit_sha} code />
            <.build_field
              label="Built at"
              value={@build_info.built_at}
              datetime={@build_info.built_at}
            />
            <.build_field label="Pipeline ID" value={@build_info.pipeline_id} code />
            <.build_field label="Trigger" value={@build_info.trigger} />
          </dl>
        </section>

        <p class="text-sm text-base-content/50">
          Build metadata contains no credentials or source contents and remains available without contacting the CI control plane.
        </p>
      </section>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :detail, :string, default: nil
  attr :datetime, :string, default: nil
  attr :code, :boolean, default: false

  defp build_field(assigns) do
    ~H"""
    <div class="grid gap-2 px-5 py-4 sm:grid-cols-[11rem_minmax(0,1fr)] sm:px-6">
      <dt class="text-sm font-semibold text-base-content/55">{@label}</dt>
      <dd class="min-w-0">
        <%= if @datetime do %>
          <time datetime={@datetime} class="break-all text-sm font-semibold">{@value}</time>
        <% else %>
          <span class={["break-all text-sm font-semibold", @code && "font-mono"]}>{@value}</span>
        <% end %>
        <span :if={@detail} class="ml-2 badge badge-ghost badge-sm">{@detail}</span>
      </dd>
    </div>
    """
  end
end
