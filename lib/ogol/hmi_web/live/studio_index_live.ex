defmodule Ogol.HMIWeb.StudioIndexLive do
  use Ogol.HMIWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Studio")
     |> assign(
       :page_summary,
       "DSL-native authoring surfaces for HMIs, hardware, topology, machines, and drivers."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :studio_home)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="grid gap-5 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)]">
      <div class="space-y-5">
        <section class="app-panel px-5 py-5">
          <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
            <div class="max-w-3xl">
              <p class="app-kicker">Studio Contract</p>
              <h2 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
                Visual editors are projections over canonical DSL
              </h2>
              <p class="mt-3 text-base leading-7 text-[var(--app-text-muted)]">
                Save, diff, compile, and activate always operate on DSL. Visual editing is available only when the system can classify and preserve semantics confidently.
              </p>
            </div>

            <div class="grid gap-2 sm:grid-cols-2">
              <.state_chip title="Visual" detail="Full bidirectional editing" tone="good" />
              <.state_chip title="Partial" detail="Section-level fallback" tone="warn" />
              <.state_chip title="DSL-only" detail="Source remains authoritative" tone="info" />
              <.state_chip title="Invalid" detail="Diagnostics, no activation" tone="danger" />
            </div>
          </div>
        </section>

        <section class="grid gap-4 md:grid-cols-2 2xl:grid-cols-5">
          <.artifact_card
            title="HMIs"
            summary="Template-first runtime surface authoring with compiled deployment and fixed viewport profiles."
            path={~p"/studio/hmis"}
            action="Open HMI Studio"
            state="active"
          />
          <.artifact_card
            title="Hardware"
            summary="First Studio-grade editor. EtherCAT-first, bidirectional, simulation-ready."
            path={~p"/studio/hardware"}
            action="Open Hardware Studio"
            state="active"
          />
          <.artifact_card
            title="Topology"
            summary="Flat deployment authoring, dependency binding, signal/status/down observation."
            path={~p"/studio/topology"}
            action="Open Topology Studio"
            state="planned"
          />
          <.artifact_card
            title="Machines"
            summary="State graph, public interface, and dependency declarations over canonical DSL."
            path={~p"/studio/machines"}
            action="Open Machine Studio"
            state="planned"
          />
          <.artifact_card
            title="Drivers"
            summary="EtherCAT driver authoring on the same visual + DSL shell."
            path={~p"/studio/drivers"}
            action="Open Driver Studio"
            state="planned"
          />
        </section>
      </div>

      <aside class="space-y-5">
        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Studio Pipeline</p>
          <ol class="mt-4 space-y-3">
            <.pipeline_step step="Load" detail="DSL -> parse -> classify -> determine visual availability -> lower where supported." />
            <.pipeline_step step="Edit" detail="Visual edits lower back to DSL. DSL edits re-parse and refresh diagnostics." />
            <.pipeline_step step="Save" detail="Only DSL drafts are persisted." />
            <.pipeline_step step="Compile" detail="Compile runs against DSL, not the visual model." />
            <.pipeline_step step="Activate / Deploy / Assign" detail="Machines activate compiled runtime artifacts; HMI surfaces deploy versions and assign them to panels." />
          </ol>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Invariants</p>
          <ul class="mt-4 space-y-3 text-sm leading-6 text-[var(--app-text-muted)]">
            <li>DSL is the only persisted authority.</li>
            <li>Unsupported constructs fail closed into DSL-first editing.</li>
            <li>Visual save flows must never silently discard unsupported semantics.</li>
            <li>Parse, classification, validation, and compile stay separate in the UI.</li>
          </ul>
        </section>
      </aside>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:summary, :string, required: true)
  attr(:path, :string, required: true)
  attr(:action, :string, required: true)
  attr(:state, :string, required: true)

  def artifact_card(assigns) do
    ~H"""
    <article class="app-panel px-4 py-4">
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="app-kicker">{@title}</p>
          <h3 class="mt-1 text-xl font-semibold text-[var(--app-text)]">{@title}</h3>
        </div>
        <span class={["studio-state", studio_state_classes(@state)]}>{@state}</span>
      </div>
      <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">{@summary}</p>
      <.link navigate={@path} class="studio-link mt-4 inline-flex">
        {@action}
      </.link>
    </article>
    """
  end

  attr(:title, :string, required: true)
  attr(:detail, :string, required: true)
  attr(:tone, :string, required: true)

  def state_chip(assigns) do
    ~H"""
    <div class={["studio-state-card", state_chip_classes(@tone)]}>
      <p class="font-mono text-[11px] uppercase tracking-[0.22em]">{@title}</p>
      <p class="mt-1 text-sm font-semibold">{@detail}</p>
    </div>
    """
  end

  attr(:step, :string, required: true)
  attr(:detail, :string, required: true)

  def pipeline_step(assigns) do
    ~H"""
    <li class="border-l-4 border-[var(--app-border)] pl-3">
      <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">{@step}</p>
      <p class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">{@detail}</p>
    </li>
    """
  end

  defp studio_state_classes("active"),
    do: "border-[var(--app-good-border)] bg-[var(--app-good-surface)] text-[var(--app-good-text)]"

  defp studio_state_classes(_),
    do: "border-[var(--app-border)] bg-[var(--app-surface-alt)] text-[var(--app-text-muted)]"

  defp state_chip_classes("good"),
    do: "border-[var(--app-good-border)] bg-[var(--app-good-surface)] text-[var(--app-good-text)]"

  defp state_chip_classes("warn"),
    do: "border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] text-[var(--app-warn-text)]"

  defp state_chip_classes("danger"),
    do:
      "border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"

  defp state_chip_classes(_tone),
    do: "border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]"
end
