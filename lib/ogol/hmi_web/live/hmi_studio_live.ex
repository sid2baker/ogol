defmodule Ogol.HMIWeb.HmiStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.StudioWorkspace
  alias Ogol.HMIWeb.HmiSurfaceStudioCellComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "HMI Studio")
     |> assign(
       :page_summary,
       "Topology-scoped HMI Studio Cells. The active topology defines which runtime surfaces exist."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :hmis)
     |> load_workspace()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_workspace(socket)}
  end

  @impl true
  def handle_info({:hmi_assignment_changed}, socket) do
    {:noreply, load_workspace(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <section :if={@workspace} class="app-panel px-5 py-5">
        <p class="app-kicker">Active Topology</p>
        <h1 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
          {@workspace.title}
        </h1>
        <p class="mt-3 max-w-4xl text-sm leading-6 text-[var(--app-text-muted)]">
          {@workspace.summary}
        </p>
      </section>

      <section :if={@workspace_error} class="app-panel px-5 py-5">
        <p class="app-kicker">No Active Topology</p>
        <h1 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
          Start a topology to author HMI cells
        </h1>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          `/studio/hmis` is topology-scoped now. Start the EtherCAT master, activate a topology, then come back here to edit the runtime HMI cells for that active topology.
        </p>

        <div class="mt-5 flex flex-wrap gap-2">
          <.link navigate={~p"/studio/ethercat"} class="app-button-secondary">
            Open EtherCAT Studio
          </.link>
          <.link navigate={~p"/studio/topology"} class="app-button">
            Open Topology Studio
          </.link>
        </div>
      </section>

      <div :if={@workspace} class="space-y-6">
        <.live_component
          :for={cell <- @workspace.cells}
          module={HmiSurfaceStudioCellComponent}
          id={cell.surface_id}
          cell={cell}
        />
      </div>
    </div>
    """
  end

  defp load_workspace(socket) do
    case StudioWorkspace.active_workspace() do
      {:ok, workspace} ->
        socket
        |> assign(:workspace, workspace)
        |> assign(:workspace_error, nil)

      {:error, reason} ->
        socket
        |> assign(:workspace, nil)
        |> assign(:workspace_error, reason)
    end
  end
end
