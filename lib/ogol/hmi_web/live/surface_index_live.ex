defmodule Ogol.HMIWeb.SurfaceIndexLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.{SurfaceCatalog, SurfaceDeployment}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Runtime Surfaces")
     |> assign(
       :page_summary,
       "Supervisor and fallback launcher for compiled, deployed operator surfaces."
     )
     |> assign(:hmi_mode, :ops)
     |> assign(:hmi_nav, :surfaces)
     |> assign(:assignments, SurfaceDeployment.list())
     |> assign(:surfaces, SurfaceCatalog.list_runtimes())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="grid gap-4 xl:grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)]">
      <section class="app-panel overflow-hidden">
        <div class="border-b border-[var(--app-border)] px-5 py-5">
          <p class="app-kicker">Deployment</p>
          <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Assigned runtime panels</h2>
          <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            Panels open their assigned surface by default. This launcher is fallback and supervisor territory.
          </p>
        </div>

        <div class="grid gap-3 p-4">
          <article
            :for={assignment <- @assignments}
            class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <p class="app-kicker">Panel</p>
                <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">{assignment.panel_id}</h3>
              </div>

              <span class="border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
                {assignment.viewport_profile}
              </span>
            </div>

            <div class="mt-3 grid gap-2 sm:grid-cols-2">
              <div class="border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-2.5">
                <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Surface</p>
                <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">{assignment.surface_id}</p>
              </div>
              <div class="border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-2.5">
                <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Version</p>
                <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">{assignment.surface_version}</p>
              </div>
            </div>

            <div class="mt-4 flex flex-wrap gap-2">
              <.link
                navigate={~p"/ops"}
                class="inline-flex border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-info-text)]"
              >
                Open assigned runtime
              </.link>
              <.link
                navigate={~p"/ops/hmis/#{assignment.surface_id}/#{assignment.default_screen}"}
                class="inline-flex border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text)]"
              >
                Open direct route
              </.link>
            </div>
          </article>
        </div>
      </section>

      <section class="app-panel overflow-hidden">
        <div class="border-b border-[var(--app-border)] px-5 py-5">
          <p class="app-kicker">Catalog</p>
          <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Compiled surface definitions</h2>
        </div>

        <div class="grid gap-3 p-4">
          <article
            :for={surface <- @surfaces}
            class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <p class="app-kicker">{surface.role}</p>
                <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">{surface.title}</h3>
              </div>
              <span class="border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
                {variant_profiles(surface)}
              </span>
            </div>

            <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">{surface.summary}</p>

            <div class="mt-4 flex flex-wrap gap-2">
              <.link
                navigate={~p"/ops/hmis/#{surface.id}/#{surface.default_screen}"}
                class="inline-flex border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text)]"
              >
                Open runtime player
              </.link>
            </div>
          </article>
        </div>
      </section>
    </section>
    """
  end

  defp variant_profiles(surface) do
    surface.screens
    |> Map.values()
    |> Enum.flat_map(fn screen -> Map.keys(screen.variants) end)
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
    |> Enum.join(" / ")
  end
end
