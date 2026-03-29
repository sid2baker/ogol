defmodule Ogol.HMIWeb.HmiStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.StudioWorkspace
  alias Ogol.HMIWeb.Components.StudioLibrary
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
  def handle_params(params, _uri, socket) do
    {:noreply, load_workspace(socket, params["surface_id"])}
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

      <section :if={@workspace} class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
        <StudioLibrary.list
          title="Screens"
          items={screen_items(@workspace)}
          current_id={@selected_surface_id}
          empty_label="No HMI screens are available for the active topology."
        />

        <div class="space-y-3">
          <h2 class="text-xl font-semibold tracking-tight text-[var(--app-text)]">
            {@selected_cell.title}
          </h2>

          <.live_component
            module={HmiSurfaceStudioCellComponent}
            id={@selected_cell.surface_id}
            cell={@selected_cell}
          />
        </div>
      </section>
    </div>
    """
  end

  defp load_workspace(socket, requested_surface_id \\ nil) do
    case StudioWorkspace.active_workspace() do
      {:ok, workspace} ->
        selected_cell = selected_cell(workspace, requested_surface_id)

        socket
        |> assign(:workspace, workspace)
        |> assign(:selected_cell, selected_cell)
        |> assign(:selected_surface_id, selected_cell.surface_id)
        |> assign(:workspace_error, nil)

      {:error, reason} ->
        socket
        |> assign(:workspace, nil)
        |> assign(:selected_cell, nil)
        |> assign(:selected_surface_id, nil)
        |> assign(:workspace_error, reason)
    end
  end

  defp selected_cell(%{cells: [first | _]} = workspace, requested_surface_id) do
    Enum.find(workspace.cells, first, fn cell ->
      to_string(cell.surface_id) == to_string(requested_surface_id)
    end)
  end

  defp screen_items(workspace) do
    Enum.map(workspace.cells, fn cell ->
      %{
        id: cell.surface_id,
        label: cell.title,
        path: ~p"/studio/hmis/#{cell.surface_id}"
      }
    end)
  end
end
