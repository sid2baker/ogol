defmodule OgolWeb.Studio.HmiLive do
  use OgolWeb, :live_view

  alias Ogol.HMI.Surface.Defaults, as: SurfaceDefaults
  alias OgolWeb.Live.SessionSync
  alias OgolWeb.Studio.CellPath
  alias OgolWeb.Studio.Library, as: StudioLibrary
  alias OgolWeb.Studio.HmiSurfaceCellComponent
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias Ogol.Session
  alias Ogol.Session.Workspace.SourceDraft

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "HMI Studio")
     |> assign(
       :page_summary,
       "Workspace-backed HMI surfaces. Runtime panels derive from deployed surface versions, while Studio edits canonical source."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :hmis)
     |> assign(:live_connected?, connected?(socket))
     |> assign(:selected_surface_id, nil)
     |> StudioRevision.subscribe()
     |> load_workspace()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_surface_id =
      if socket.assigns.live_action in [:show, :cell], do: params["surface_id"], else: nil

    socket =
      socket
      |> StudioRevision.apply_param(params)
      |> SessionSync.ensure_entry(:hmi_surface, requested_surface_id)

    socket = load_workspace(socket, requested_surface_id)

    {:noreply, maybe_canonicalize_surface_path(socket, requested_surface_id)}
  end

  @impl true
  def handle_info({:hmi_assignment_changed}, socket) do
    {:noreply, load_workspace(socket, socket.assigns[:selected_surface_id])}
  end

  def handle_info({:operations, operations}, socket) do
    {:noreply,
     socket
     |> StudioRevision.apply_operations(operations)
     |> load_workspace(socket.assigns[:selected_surface_id])}
  end

  def handle_info({:runtime_updated, _action, _reply}, socket) do
    {:noreply, load_workspace(socket, socket.assigns[:selected_surface_id])}
  end

  @impl true
  def handle_event("generate_from_topology", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, socket}
    else
      drafts = SurfaceDefaults.drafts_from_workspace()

      {:noreply,
       socket
       |> then(fn current ->
         if drafts == [] do
           current
         else
           Session.replace_hmi_surfaces(drafts)
           SessionSync.refresh(current)
         end
       end)
       |> load_workspace()}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @live_action == :cell do %>
      <.live_component
        :if={@selected_cell}
        module={HmiSurfaceCellComponent}
        id={@selected_cell.id}
        cell={@selected_cell}
        live_connected?={@live_connected?}
        body_only?={true}
      />

      <section :if={!@selected_cell} class="app-panel px-5 py-5">
        <p class="app-kicker">No HMI Surfaces</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          No HMI source is in the workspace
        </h2>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          {@workspace_error_message}
        </p>
      </section>
    <% else %>
      <%= if @live_action == :show do %>
        <section :if={@workspace} class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
          <StudioLibrary.list
            title="Screens"
            items={screen_items(@workspace)}
            current_id={@selected_surface_id}
            empty_label="No HMI surfaces are in the workspace."
          />

          <div class="space-y-3">
            <h2 class="text-xl font-semibold tracking-tight text-[var(--app-text)]">
              {surface_title(@selected_cell)}
            </h2>

            <.live_component
              module={HmiSurfaceCellComponent}
              id={@selected_cell.id}
              cell={@selected_cell}
              live_connected?={@live_connected?}
              body_only?={false}
            />
          </div>
        </section>

        <section :if={!@workspace} class="app-panel px-5 py-5">
          <p class="app-kicker">No HMI Surfaces</p>
          <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
            No HMI source is in the workspace
          </h2>
          <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
            {@workspace_error_message}
          </p>
        </section>
      <% else %>
        <div class="space-y-6">
          <section class="app-panel px-5 py-5">
            <p class="app-kicker">Workspace HMI</p>
            <h1 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
              HMI Surfaces
            </h1>
            <p class="mt-3 max-w-4xl text-sm leading-6 text-[var(--app-text-muted)]">
              {@page_summary}
            </p>

            <div class="mt-5 flex flex-wrap gap-2">
              <button
                type="button"
                phx-click="generate_from_topology"
                class="app-button-secondary"
                disabled={@generate_disabled?}
              >
                Generate From Current Topology
              </button>
            </div>
          </section>

          <section :if={@workspace_error} class="app-panel px-5 py-5">
            <p class="app-kicker">No HMI Surfaces</p>
            <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
              No HMI source is in the workspace
            </h2>
            <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
              {@workspace_error_message}
            </p>
          </section>

          <section :if={@workspace} class="grid gap-5">
            <StudioLibrary.list
              title="Screens"
              items={screen_items(@workspace)}
              current_id={nil}
              empty_label="No HMI surfaces are in the workspace."
            />
          </section>
        </div>
      <% end %>
    <% end %>
    """
  end

  defp load_workspace(socket, requested_surface_id \\ nil) do
    drafts = SessionSync.list_entries(socket, :hmi_surface)
    selected_cell = selected_cell(drafts, requested_surface_id)

    socket
    |> assign(:generate_disabled?, SurfaceDefaults.drafts_from_workspace() == [])
    |> assign(:workspace, if(selected_cell, do: %{cells: drafts}, else: nil))
    |> assign(:selected_cell, selected_cell)
    |> assign(:selected_surface_id, selected_cell && selected_cell.id)
    |> assign(:workspace_error, if(selected_cell, do: nil, else: :no_hmi_surfaces))
    |> assign(:workspace_error_message, workspace_error_message())
  end

  defp selected_cell([first | _] = drafts, requested_surface_id) do
    Enum.find(drafts, first, fn draft ->
      draft.id == to_string(requested_surface_id)
    end)
  end

  defp selected_cell([], _requested_surface_id), do: nil

  defp screen_items(%{cells: cells}) do
    Enum.map(cells, fn draft ->
      %{
        id: draft.id,
        label: surface_title(draft),
        path: CellPath.page_path(:hmi_surface, draft.id)
      }
    end)
  end

  defp maybe_canonicalize_surface_path(socket, _requested_surface_id)
       when socket.assigns.live_action not in [:show, :cell],
       do: socket

  defp maybe_canonicalize_surface_path(
         %{assigns: %{selected_surface_id: nil}} = socket,
         _requested_surface_id
       ),
       do: socket

  defp maybe_canonicalize_surface_path(socket, requested_surface_id) do
    path =
      case socket.assigns.live_action do
        :cell -> CellPath.show_path(:hmi_surface, socket.assigns.selected_surface_id)
        :show -> CellPath.page_path(:hmi_surface, socket.assigns.selected_surface_id)
      end

    if socket.assigns.selected_surface_id == requested_surface_id do
      socket
    else
      push_patch(socket, to: path)
    end
  end

  defp workspace_error_message do
    "Generate surfaces from the current topology or load a revision that already includes HMI source."
  end

  defp surface_title(%SourceDraft{model: %{title: title}})
       when is_binary(title) and title != "",
       do: title

  defp surface_title(%SourceDraft{id: id}), do: humanize(id)

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
