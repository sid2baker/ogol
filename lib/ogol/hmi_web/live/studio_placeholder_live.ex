defmodule Ogol.HMIWeb.StudioPlaceholderLive do
  use Ogol.HMIWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {title, summary, nav} = placeholder_content(socket.assigns.live_action)

    {:ok,
     socket
     |> assign(:page_title, title)
     |> assign(:page_summary, summary)
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, nav)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="mx-auto max-w-4xl">
      <div class="app-panel px-6 py-6">
        <p class="app-kicker">Studio Placeholder</p>
        <h2 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">{@page_title}</h2>
        <p class="mt-3 max-w-3xl text-base leading-7 text-[var(--app-text-muted)]">
          {@page_summary}
        </p>

        <div class="mt-6 grid gap-4 md:grid-cols-2">
          <div class="app-panel-muted px-4 py-4">
            <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
              Planned scope
            </p>
            <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
              This area will use the shared Visual / Source Studio Cell shell, compatibility banner, diagnostics panel, and explicit save / compile / activate or deploy controls.
            </p>
          </div>
          <div class="app-panel-muted px-4 py-4">
            <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
              Current path
            </p>
            <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
              Simulator and EtherCAT are now split into separate Studio surfaces. HMI, topology, machine, and driver Studio surfaces continue to build on the same source-first shell rather than inventing page-specific editors.
            </p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp placeholder_content(:hmis) do
    {"HMI Studio",
     "Runtime HMIs are authored as source-defined, compiled, deployable operator surfaces. This area will host template-first surface authoring, source editing, compile, and deploy flows.",
     :hmis}
  end

  defp placeholder_content(:topology) do
    {"Topology Studio",
     "Flat-topology authoring will live here: machine instances, dependency binding, and signal/status/down observation over canonical source.",
     :topology}
  end

  defp placeholder_content(:machines) do
    {"Machine Studio",
     "Machine authoring will live here after the shared Studio shell is proven on hardware and topology. The output remains canonical Ogol source.",
     :machines}
  end

  defp placeholder_content(:drivers) do
    {"Driver Studio",
     "EtherCAT driver authoring will live here on the same Studio kernel, with visual editing available only for semantically preservable source constructs.",
     :drivers}
  end
end
