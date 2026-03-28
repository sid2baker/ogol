defmodule Ogol.HMIWeb.MachineStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMIWeb.Components.StudioCell

  @editor_modes [:visual, :source]

  @source_preview """
  machine :packaging_line do
    statechart do
      state :idle, initial?: true
      state :running
      state :faulted
    end

    commands do
      command :start_cycle
      command :stop_cycle
      command :reset_fault
    end

    observe do
      status :line_ready
      signal :outfeed_ready
    end
  end
  """

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Machine Studio")
     |> assign(
       :page_summary,
       "Machine authoring will reuse Studio Cells for visual/source switching, diagnostics, and runtime-safe build/apply workflows once the machine artifact kernel is implemented."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :machines)
     |> assign(:editor_modes, @editor_modes)
     |> assign(:editor_mode, :visual)
     |> assign(:studio_feedback, nil)
     |> assign(:source_preview, @source_preview)}
  end

  @impl true
  def handle_event("set_editor_mode", %{"mode" => mode}, socket) do
    mode =
      mode
      |> String.to_existing_atom()
      |> then(fn mode -> if mode in @editor_modes, do: mode, else: :visual end)

    {:noreply, assign(socket, :editor_mode, mode)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("build_machine", _params, socket) do
    {:noreply,
     assign(
       socket,
       :studio_feedback,
       feedback(
         :info,
         "Build not wired yet",
         "Machine Studio already uses the shared Studio Cell shell, but the machine build/apply kernel is the next slice."
       )
     )}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :header_notice, header_notice(assigns))

    ~H"""
    <StudioCell.cell>
      <:actions>
        <button type="button" phx-click="build_machine" class="app-button-secondary">
          Build
        </button>
      </:actions>

      <:modes>
        <StudioCell.toggle_button
          :for={mode <- @editor_modes}
          type="button"
          phx-click="set_editor_mode"
          phx-value-mode={mode}
          active={@editor_mode == mode}
        >
          {mode_label(mode)}
        </StudioCell.toggle_button>
      </:modes>

      <:notice :if={@header_notice}>
        <StudioCell.notice
          level={@header_notice.level}
          title={@header_notice.title}
          detail={@header_notice.detail}
        />
      </:notice>

      <:footer>
        <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,0.9fr)]">
          <div>
            <p class="app-kicker">Current Cell State</p>
            <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
              This page exists to prove that Studio Cells can be reused outside driver authoring without copying the shell markup again.
            </p>
          </div>
          <div class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
            <p class="app-kicker">Next Machine Slice</p>
            <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
              Add machine draft storage, source recovery, validation diagnostics, and the same build/apply gating used by the driver cell.
            </p>
          </div>
        </div>
      </:footer>

      <%= if @editor_mode == :visual do %>
        <div class="grid gap-4 xl:grid-cols-2">
          <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
            <p class="app-kicker">General Configuration</p>
            <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
              Machine cells will keep machine metadata, statechart identity, and command surface in the top section of the same card.
            </p>
          </section>

          <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
            <p class="app-kicker">Execution Model</p>
            <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
              Runtime state stays outside generated modules. The cell will author canonical source, then build and apply runtime-safe artifacts through the shared Studio kernel.
            </p>
          </section>

          <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4 xl:col-span-2">
            <p class="app-kicker">Planned Visual Areas</p>
            <div class="mt-3 grid gap-3 md:grid-cols-3">
              <div class="app-panel-muted px-4 py-4">
                <p class="font-semibold text-[var(--app-text)]">Statechart</p>
                <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                  State and transition authoring over a constrained, semantically preservable subset.
                </p>
              </div>
              <div class="app-panel-muted px-4 py-4">
                <p class="font-semibold text-[var(--app-text)]">Commands</p>
                <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                  Public machine skills, guards, and command wiring surfaced as a managed projection.
                </p>
              </div>
              <div class="app-panel-muted px-4 py-4">
                <p class="font-semibold text-[var(--app-text)]">Observation</p>
                <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                  Status, signals, and dependency projections curated for machine runtime behavior.
                </p>
              </div>
            </div>
          </section>
        </div>
      <% else %>
        <form class="space-y-3">
          <textarea
            readonly
            class="app-textarea h-[30rem] w-full font-mono text-[13px] leading-6"
          ><%= @source_preview %></textarea>
          <p class="text-sm leading-6 text-[var(--app-text-muted)]">
            This is a preview of the canonical machine source shape the future Machine Studio cell will edit and recover visually.
          </p>
        </form>
      <% end %>
    </StudioCell.cell>
    """
  end

  defp mode_label(:visual), do: "Visual"
  defp mode_label(:source), do: "Source"

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}

  defp header_notice(%{studio_feedback: nil}), do: nil
  defp header_notice(%{studio_feedback: feedback}), do: feedback
end
