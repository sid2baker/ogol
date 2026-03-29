defmodule Ogol.HMIWeb.HmiStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.StudioWorkspace
  alias Ogol.Studio.Bundle
  alias Ogol.HMIWeb.Components.StudioLibrary
  alias Ogol.HMIWeb.HmiSurfaceStudioCellComponent
  alias Ogol.HMIWeb.StudioRevision

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
    socket = StudioRevision.apply_param(socket, params)
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
          {@workspace_error_message}
        </p>

        <div class="mt-5 flex flex-wrap gap-2">
          <.link
            navigate={StudioRevision.path_with_revision(~p"/studio/ethercat", @studio_selected_revision)}
            class="app-button-secondary"
          >
            Open EtherCAT Studio
          </.link>
          <.link
            navigate={StudioRevision.path_with_revision(~p"/studio/topology", @studio_selected_revision)}
            class="app-button"
          >
            Open Topology Studio
          </.link>
        </div>
      </section>

      <section :if={@workspace} class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
        <StudioLibrary.list
          title="Screens"
          items={screen_items(@workspace, @studio_selected_revision)}
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
            surface_artifact={selected_surface_artifact(@studio_selected_revision_bundle, @selected_cell)}
            read_only?={@studio_read_only?}
          />
        </div>
      </section>
    </div>
    """
  end

  defp load_workspace(socket, requested_surface_id \\ nil) do
    workspace_result =
      case StudioRevision.selected_bundle(socket.assigns) do
        %Bundle{} = bundle -> StudioWorkspace.workspace_from_bundle(bundle)
        nil -> StudioWorkspace.active_workspace()
      end

    case workspace_result do
      {:ok, workspace} ->
        selected_cell = selected_cell(workspace, requested_surface_id)

        socket
        |> assign(:workspace, workspace)
        |> assign(:selected_cell, selected_cell)
        |> assign(:selected_surface_id, selected_cell.surface_id)
        |> assign(:workspace_error, nil)
        |> assign(:workspace_error_message, nil)

      {:error, reason} ->
        socket
        |> assign(:workspace, nil)
        |> assign(:selected_cell, nil)
        |> assign(:selected_surface_id, nil)
        |> assign(:workspace_error, reason)
        |> assign(:workspace_error_message, workspace_error_message(reason))
    end
  end

  defp selected_cell(%{cells: [first | _]} = workspace, requested_surface_id) do
    Enum.find(workspace.cells, first, fn cell ->
      to_string(cell.surface_id) == to_string(requested_surface_id)
    end)
  end

  defp screen_items(workspace, selected_revision) do
    Enum.map(workspace.cells, fn cell ->
      %{
        id: cell.surface_id,
        label: cell.title,
        path:
          StudioRevision.path_with_revision(
            ~p"/studio/hmis/#{cell.surface_id}",
            selected_revision
          )
      }
    end)
  end

  defp selected_surface_artifact(%Bundle{} = bundle, cell) do
    Bundle.artifact(bundle, :hmi_surface, cell.surface_id)
  end

  defp selected_surface_artifact(_bundle, _cell), do: nil

  defp workspace_error_message(:no_active_topology) do
    "/studio/hmis is topology-scoped now. Start the EtherCAT master, activate a topology, then come back here to edit the runtime HMI cells for that active topology."
  end

  defp workspace_error_message(:no_revision_topology) do
    "The selected revision does not contain a topology snapshot, so there are no revision-scoped HMI screens to open."
  end

  defp workspace_error_message(_other) do
    "The current topology workspace could not be recovered."
  end
end
