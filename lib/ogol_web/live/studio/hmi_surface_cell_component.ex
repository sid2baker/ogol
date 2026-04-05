defmodule OgolWeb.Studio.HmiSurfaceCellComponent do
  use OgolWeb, :live_component

  alias Ogol.HMI.Surface.Template
  alias Ogol.HMI.Surface.Compiler.Analysis
  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.Compiler, as: SurfaceCompiler
  alias Ogol.HMI.Surface.Deployments, as: SurfaceDeployment
  alias Ogol.HMI.Surface.Printer, as: SurfacePrinter
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore
  alias OgolWeb.HMI.OverviewSurface
  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias Ogol.HMI.Surface.Studio.Cell, as: HmiSurfaceCell
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell, as: StudioCellState
  alias Ogol.Session
  alias Ogol.Session.Workspace.SourceDraft

  @preview_supported_widgets [
    :summary_strip,
    :alarm_strip,
    :procedure_panel,
    :attention_lane,
    :machine_grid,
    :event_ticker,
    :quick_links,
    :skill_button_group,
    :status_tile,
    :value_grid,
    :fault_list,
    :machine_summary_card
  ]

  @impl true
  def update(%{cell: %SourceDraft{} = cell} = assigns, socket) do
    read_only? = Map.get(assigns, :read_only?, socket.assigns[:read_only?] || false)

    live_connected? =
      Map.get(assigns, :live_connected?, socket.assigns[:live_connected?] || false)

    body_only? = Map.get(assigns, :body_only?, socket.assigns[:body_only?] || false)

    runtime_entry =
      SurfaceRuntimeStore.fetch_or_default(cell.id, source_module: cell.source_module)

    analysis = SurfaceCompiler.analyze(cell.source)
    current_assignment = SurfaceDeployment.default_assignment()

    selected_profile =
      resolve_selected_profile(
        socket.assigns[:selected_profile],
        analysis.runtime,
        current_assignment
      )

    requested_view =
      socket.assigns[:requested_view] || HmiSurfaceCell.default_requested_view(analysis)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:cell, cell)
     |> assign(:surface_runtime_entry, runtime_entry)
     |> assign(:read_only?, read_only?)
     |> assign(:live_connected?, live_connected?)
     |> assign(:body_only?, body_only?)
     |> assign(:requested_view, requested_view)
     |> assign(:selected_profile, selected_profile)
     |> assign(:studio_feedback, socket.assigns[:studio_feedback])
     |> assign(:current_assignment, current_assignment)
     |> assign_analysis(cell.source, analysis)}
  end

  @impl true
  def handle_event("select_view", %{"view" => view}, socket) do
    requested_view =
      view
      |> String.to_existing_atom()
      |> then(fn parsed ->
        if parsed in [:configuration, :preview, :source], do: parsed, else: :source
      end)

    {:noreply, assign(socket, :requested_view, requested_view)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("select_profile", %{"profile" => profile}, socket) do
    selected_profile =
      try do
        String.to_existing_atom(profile)
      rescue
        ArgumentError -> socket.assigns.selected_profile
      end

    {:noreply, assign(socket, :selected_profile, selected_profile)}
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    if socket.assigns.read_only? do
      {:noreply, readonly_surface(socket)}
    else
      analysis = SurfaceCompiler.analyze(source)

      sync_state =
        case analysis.classification do
          :visual -> :synced
          _other -> :unsupported
        end

      model = if analysis.classification == :visual, do: analysis.definition, else: nil

      draft =
        Session.save_hmi_surface_source(
          socket.assigns.cell.id,
          source,
          socket.assigns.cell.source_module,
          model,
          sync_state,
          analysis.diagnostics
        )

      {:noreply,
       socket
       |> assign(:cell, draft)
       |> assign(:studio_feedback, nil)
       |> assign_analysis(source, analysis)}
    end
  end

  def handle_event("request_transition", %{"transition" => transition}, socket)
      when transition in ["compile", "recompile"] do
    if socket.assigns.read_only? do
      {:noreply, readonly_surface(socket)}
    else
      if SurfaceCompiler.ready?(socket.assigns.source_analysis) do
        entry =
          SurfaceRuntimeStore.compile(
            socket.assigns.cell.id,
            socket.assigns.source_analysis.definition,
            socket.assigns.source_analysis.runtime,
            source_digest: socket.assigns.current_source_digest,
            source_module: socket.assigns.cell.source_module
          )

        {:noreply,
         socket
         |> assign(:surface_runtime_entry, entry)
         |> assign(
           :studio_feedback,
           feedback(:good, "Compiled", "#{entry.compiled_version} ready for deployment.")
         )}
      else
        {:noreply,
         assign(
           socket,
           :studio_feedback,
           feedback(
             :danger,
             "Compile blocked",
             "Resolve source diagnostics before compiling this surface."
           )
         )}
      end
    end
  end

  def handle_event("request_transition", %{"transition" => "delete"}, socket) do
    if socket.assigns.read_only? do
      {:noreply, readonly_surface(socket)}
    else
      :ok = Session.dispatch({:delete_entry, :hmi_surface, socket.assigns.cell.id})
      {:noreply, socket}
    end
  end

  def handle_event("request_transition", %{"transition" => "deploy"}, socket) do
    if socket.assigns.read_only? do
      {:noreply, readonly_surface(socket)}
    else
      case socket.assigns.surface_runtime_entry.compiled_runtime do
        %Surface.Runtime{} ->
          entry = SurfaceRuntimeStore.deploy(socket.assigns.cell.id)

          {:noreply,
           socket
           |> assign(:surface_runtime_entry, entry)
           |> assign(
             :studio_feedback,
             feedback(
               :good,
               "Deployed",
               "#{entry.deployed_version} published for runtime assignment."
             )
           )}

        _ ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :danger,
               "Deploy blocked",
               "Compile a valid HMI surface before deploying it."
             )
           )}
      end
    end
  end

  def handle_event("request_transition", %{"transition" => "assign_panel"}, socket) do
    if socket.assigns.read_only? do
      {:noreply, readonly_surface(socket)}
    else
      case socket.assigns.surface_runtime_entry.deployed_version do
        nil ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :danger,
               "Assignment blocked",
               "Deploy a surface version before assigning it."
             )
           )}

        _ ->
          assignment =
            SurfaceDeployment.assign_panel(
              socket.assigns.current_assignment.panel_id,
              socket.assigns.cell.id,
              version: socket.assigns.surface_runtime_entry.deployed_version
            )

          send(self(), {:hmi_assignment_changed})

          {:noreply,
           socket
           |> assign(:current_assignment, assignment)
           |> assign(
             :studio_feedback,
             feedback(
               :good,
               "Assigned",
               "Panel #{assignment.panel_id} now opens #{assignment.surface_id}@#{assignment.surface_version}."
             )
           )}
      end
    end
  end

  def handle_event("change_metadata", %{"surface" => params}, socket) do
    if socket.assigns.read_only? do
      {:noreply, readonly_surface(socket)}
    else
      case socket.assigns.surface_definition do
        %Surface{} = definition ->
          updated =
            definition
            |> Map.put(:title, Map.get(params, "title", definition.title))
            |> Map.put(:summary, Map.get(params, "summary", definition.summary))

          {:noreply, apply_visual_update(socket, updated)}

        _ ->
          {:noreply, socket}
      end
    end
  end

  def handle_event("change_zone_config", %{"zones" => params}, socket) do
    if socket.assigns.read_only? do
      {:noreply, readonly_surface(socket)}
    else
      with %Surface{} = definition <- socket.assigns.surface_definition,
           profile when not is_nil(profile) <- socket.assigns.selected_profile,
           %Surface.Variant{} = variant <- current_variant(definition, profile) do
        updated_variant =
          %{variant | zones: update_zone_map(definition.template, variant.zones, params)}

        {:noreply, apply_visual_update(socket, put_variant(definition, profile, updated_variant))}
      else
        _ -> {:noreply, socket}
      end
    end
  end

  @impl true
  def render(assigns) do
    surface_facts = HmiSurfaceCell.facts_from_assigns(assigns)

    assigns =
      assign(assigns, :surface_cell, StudioCellState.derive(HmiSurfaceCell, surface_facts))

    ~H"""
    <div id={"hmi-cell-#{@cell.id}"}>
      <%= if @body_only? do %>
        <.surface_body
          surface_cell={@surface_cell}
          cell={@cell}
          available_profiles={@available_profiles}
          selected_profile={@selected_profile}
          surface_runtime={@surface_runtime}
          surface_screen={@surface_screen}
          surface_variant={@surface_variant}
          surface_context={@surface_context}
          surface_definition={@surface_definition}
          read_only?={@read_only?}
          live_connected?={@live_connected?}
          draft_source={@draft_source}
          myself={@myself}
        />
      <% else %>
        <StudioCell.cell>
          <:actions>
            <StudioCell.action_button
              :for={control <- @surface_cell.controls}
              type="button"
              phx-click="request_transition"
              phx-target={@myself}
              phx-value-transition={control.id}
              variant={control.variant}
              disabled={@read_only? or !@live_connected? or !control.enabled?}
              title={
                cond do
                  @read_only? -> StudioRevision.readonly_message()
                  not @live_connected? -> "Waiting for the live session to connect."
                  true -> control.disabled_reason
                end
              }
            >
              {control.label}
            </StudioCell.action_button>
          </:actions>

          <:notice :if={@surface_cell.notice}>
            <StudioCell.notice
              tone={@surface_cell.notice.tone}
              title={@surface_cell.notice.title}
              message={@surface_cell.notice.message}
            />
          </:notice>

          <:views>
            <StudioCell.view_button
              :for={view <- @surface_cell.views}
              type="button"
              phx-click="select_view"
              phx-target={@myself}
              phx-value-view={view.id}
              selected={@surface_cell.selected_view == view.id}
              available={view.available?}
            >
              {view.label}
            </StudioCell.view_button>
          </:views>

          <:body>
            <.surface_body
              surface_cell={@surface_cell}
              cell={@cell}
              available_profiles={@available_profiles}
              selected_profile={@selected_profile}
              surface_runtime={@surface_runtime}
              surface_screen={@surface_screen}
              surface_variant={@surface_variant}
              surface_context={@surface_context}
              surface_definition={@surface_definition}
              read_only?={@read_only?}
              live_connected?={@live_connected?}
              draft_source={@draft_source}
              myself={@myself}
            />
          </:body>
        </StudioCell.cell>
      <% end %>
    </div>
    """
  end

  attr(:surface_cell, :map, required: true)
  attr(:cell, :map, required: true)
  attr(:available_profiles, :list, default: [])
  attr(:selected_profile, :atom, default: nil)
  attr(:surface_runtime, :any, default: nil)
  attr(:surface_screen, :any, default: nil)
  attr(:surface_variant, :any, default: nil)
  attr(:surface_context, :map, default: %{})
  attr(:surface_definition, :any, default: nil)
  attr(:read_only?, :boolean, default: false)
  attr(:live_connected?, :boolean, default: false)
  attr(:draft_source, :string, required: true)
  attr(:myself, :any, required: true)

  defp surface_body(assigns) do
    ~H"""
    <div class="space-y-4">
      <section :if={@surface_cell.selected_view == :preview} class="app-panel overflow-hidden">
                <div class="flex items-center justify-between border-b border-[var(--app-border)] px-5 py-4">
                  <p class="app-kicker">Preview</p>

                  <div class="flex flex-wrap gap-2">
                    <button
                      :for={profile <- @available_profiles}
                      type="button"
                      phx-click="select_profile"
                      phx-target={@myself}
                      phx-value-profile={profile}
                      class={profile_button_classes(@selected_profile == profile)}
                    >
                      {profile}
                    </button>
                  </div>
                </div>

                <div :if={@surface_runtime && @surface_screen && @surface_variant} class="h-[42rem] overflow-hidden p-4">
                  <OverviewSurface.render
                    surface={@surface_runtime}
                    screen={@surface_screen}
                    variant={@surface_variant}
                    context={@surface_context}
                    operator_feedback={nil}
                  />
                </div>

                <div
                  :if={is_nil(@surface_runtime) or is_nil(@surface_screen) or is_nil(@surface_variant)}
                  class="px-5 py-6"
                >
                  <p class="app-kicker">Visual Unavailable</p>
                  <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                    This surface is currently outside the managed visual subset. Switch to Source to repair it.
                  </p>
                </div>
            </section>

            <div :if={@surface_cell.selected_view == :configuration} class="space-y-4">
              <section class="app-panel px-5 py-5">
                <p class="app-kicker">Surface</p>

                <form
                  :if={@surface_definition}
                  id={"hmi-surface-metadata-#{@cell.id}"}
                  phx-change="change_metadata"
                  phx-auto-recover="change_metadata"
                  phx-target={@myself}
                  class="mt-4 grid gap-4"
                >
                  <fieldset disabled={@read_only? or !@live_connected?} class="contents">
                  <label class="space-y-1.5">
                    <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Title</span>
                    <input
                      type="text"
                      name="surface[title]"
                      value={@surface_definition.title}
                      phx-debounce="blur"
                      class={input_classes()}
                    />
                  </label>

                  <label class="space-y-1.5">
                    <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Summary</span>
                    <textarea
                      name="surface[summary]"
                      rows="4"
                      phx-debounce="blur"
                      class={textarea_classes()}
                    >{@surface_definition.summary}</textarea>
                  </label>
                  </fieldset>
                </form>
              </section>

              <section class="app-panel px-5 py-5">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <p class="app-kicker">Screen</p>
                    <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                      Choose a profile, then configure each zone by selecting a widget and the binding it should render.
                    </p>
                  </div>

                  <div class="flex flex-wrap gap-2">
                    <button
                      :for={profile <- @available_profiles}
                      type="button"
                      phx-click="select_profile"
                      phx-target={@myself}
                      phx-value-profile={profile}
                      class={profile_button_classes(@selected_profile == profile)}
                    >
                      {profile}
                    </button>
                  </div>
                </div>

                <form
                  :if={@surface_variant}
                  id={"hmi-surface-zones-#{@cell.id}"}
                  phx-change="change_zone_config"
                  phx-auto-recover="change_zone_config"
                  phx-target={@myself}
                  class="mt-4 space-y-4"
                >
                  <fieldset disabled={@read_only? or !@live_connected?} class="contents">
                  <section
                    :for={zone <- ordered_variant_zones(@surface_variant)}
                    class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
                  >
                    <div class="flex flex-wrap items-start justify-between gap-3">
                      <div>
                        <p class="font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
                          {zone.id}
                        </p>
                        <h3 class="mt-1 text-base font-semibold text-[var(--app-text)]">
                          {zone_title(zone.id)}
                        </h3>
                      </div>

                      <p class="text-sm leading-6 text-[var(--app-text-muted)]">
                        {zone_area_label(zone)}
                      </p>
                    </div>

                    <div class="mt-4 grid gap-4 xl:grid-cols-2">
                      <%= if zone_widget_editable?(zone) do %>
                        <label class="space-y-1.5">
                          <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Widget</span>
                          <select
                            name={"zones[#{zone.id}][type]"}
                            class={select_classes()}
                            disabled={editable_widget_options(@surface_definition, zone.id) == []}
                          >
                            <option
                              :for={widget_type <- editable_widget_options(@surface_definition, zone.id)}
                              value={widget_type}
                              selected={zone_widget_type(zone) == widget_type}
                            >
                              {widget_type_label(widget_type)}
                            </option>
                          </select>
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Binding</span>
                          <select
                            name={"zones[#{zone.id}][binding]"}
                            class={select_classes()}
                            disabled={is_nil(@surface_definition)}
                          >
                            <option value="">none</option>
                            <option
                              :for={binding <- bindings_for_zone(@surface_definition, zone)}
                              value={binding.name}
                              selected={zone_binding(zone) == binding.name}
                            >
                              {binding_label(binding)}
                            </option>
                          </select>
                        </label>
                      <% else %>
                        <label class="space-y-1.5">
                          <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Layout</span>
                          <input type="text" value={widget_type_label(zone_widget_type(zone))} class={input_classes()} disabled />
                        </label>

                        <div class="space-y-1.5">
                          <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Binding</span>
                          <p class="rounded-xl border border-dashed border-[var(--app-border)] px-3 py-2 text-sm leading-6 text-[var(--app-text-muted)]">
                            This zone uses a grouped layout. Edit the source to change its child widgets and bindings.
                          </p>
                        </div>
                      <% end %>
                    </div>

                    <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
                      {binding_detail(@surface_definition, zone)}
                    </p>

                    <div :if={zone_has_options?(zone)} class="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-3">
                      <label :if={zone_supports_label?(zone)} class="space-y-1.5">
                        <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Label</span>
                        <input
                          type="text"
                          name={"zones[#{zone.id}][label]"}
                          value={zone_option(zone, :label)}
                          placeholder="Label"
                          phx-debounce="blur"
                          class={input_classes()}
                        />
                      </label>

                      <label :if={zone_supports_field?(zone)} class="space-y-1.5">
                        <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Field</span>
                        <input
                          type="text"
                          name={"zones[#{zone.id}][field]"}
                          value={zone_option(zone, :field)}
                          placeholder="Field"
                          phx-debounce="blur"
                          class={input_classes()}
                        />
                      </label>

                      <label :if={zone_supports_fields?(zone)} class="space-y-1.5">
                        <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Fields</span>
                        <input
                          type="text"
                          name={"zones[#{zone.id}][fields]"}
                          value={zone_fields(zone)}
                          placeholder="field_a,field_b"
                          phx-debounce="blur"
                          class={input_classes()}
                        />
                      </label>

                      <label :if={zone_supports_limit?(zone)} class="space-y-1.5">
                        <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Limit</span>
                        <input
                          type="number"
                          name={"zones[#{zone.id}][limit]"}
                          value={zone_option(zone, :limit)}
                          placeholder="Limit"
                          phx-debounce="blur"
                          class={input_classes()}
                        />
                      </label>

                      <label :if={zone_supports_index?(zone)} class="space-y-1.5">
                        <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Index</span>
                        <input
                          type="number"
                          name={"zones[#{zone.id}][index]"}
                          value={zone_option(zone, :index)}
                          placeholder="Index"
                          phx-debounce="blur"
                          class={input_classes()}
                        />
                      </label>
                    </div>
                  </section>
                  </fieldset>
                </form>
              </section>
            </div>

            <section :if={@surface_cell.selected_view == :source} class="app-panel overflow-hidden">
              <div class="border-b border-[var(--app-border)] px-5 py-4">
                <p class="app-kicker">Source</p>
              </div>

              <form
                id={"hmi-surface-source-#{@cell.id}"}
                phx-change="change_source"
                phx-auto-recover="change_source"
                phx-target={@myself}
                class="p-4"
              >
                <fieldset disabled={@read_only? or !@live_connected?} class="contents">
                  <textarea name="draft[source]" rows="32" class={dsl_textarea_classes()} phx-debounce="400">{@draft_source}</textarea>
                </fieldset>
              </form>
      </section>
    </div>
    """
  end

  defp assign_analysis(socket, source, %Analysis{} = analysis) do
    definition = if analysis.classification == :visual, do: analysis.definition, else: nil
    runtime = if analysis.classification == :visual, do: analysis.runtime, else: nil
    screen = runtime && Surface.find_screen(runtime, runtime.default_screen)
    available_profiles = available_profiles(screen)

    selected_profile =
      normalize_selected_profile(socket.assigns.selected_profile, available_profiles)

    variant = screen && selected_profile && Surface.select_variant(screen, selected_profile)

    socket
    |> assign(:draft_source, source)
    |> assign(:current_source_digest, Build.digest(source))
    |> assign(:source_analysis, analysis)
    |> assign(:surface_definition, definition)
    |> assign(:surface_runtime, runtime)
    |> assign(:surface_screen, screen)
    |> assign(:available_profiles, available_profiles)
    |> assign(:selected_profile, selected_profile)
    |> assign(:surface_variant, variant)
    |> assign(:surface_context, preview_context(runtime))
  end

  defp apply_visual_update(socket, %Surface{} = definition) do
    source = SurfacePrinter.print(definition, module: socket.assigns.cell.source_module)
    analysis = SurfaceCompiler.analyze(source)

    if SurfaceCompiler.ready?(analysis) do
      draft =
        Session.save_hmi_surface_source(
          socket.assigns.cell.id,
          source,
          socket.assigns.cell.source_module,
          analysis.definition,
          :synced,
          analysis.diagnostics
        )

      socket
      |> assign(:cell, draft)
      |> assign(:studio_feedback, nil)
      |> assign_analysis(source, analysis)
    else
      assign(
        socket,
        :studio_feedback,
        feedback(
          :danger,
          "Visual update rejected",
          hd(analysis.diagnostics) || "This change would leave the surface invalid."
        )
      )
    end
  end

  defp preview_context(%Surface.Runtime{} = runtime),
    do: Template.build_context(runtime, event_limit: 6)

  defp preview_context(_runtime), do: %{}

  defp resolve_selected_profile(current, nil, _assignment), do: current

  defp resolve_selected_profile(current, %Surface.Runtime{} = runtime, assignment) do
    available =
      runtime
      |> Surface.find_screen(runtime.default_screen)
      |> available_profiles()

    cond do
      current in available -> current
      assignment.viewport_profile in available -> assignment.viewport_profile
      available != [] -> hd(available)
      true -> nil
    end
  end

  defp normalize_selected_profile(current, available) do
    cond do
      current in available -> current
      available != [] -> hd(available)
      true -> nil
    end
  end

  defp available_profiles(nil), do: []

  defp available_profiles(screen) do
    screen.variants
    |> Map.keys()
    |> Enum.sort()
  end

  defp current_variant(%Surface{} = definition, profile) when is_atom(profile) do
    definition
    |> current_screen_definition()
    |> case do
      nil -> nil
      screen -> Map.get(screen.variants, profile)
    end
  end

  defp current_variant(_definition, _profile), do: nil

  defp current_screen_definition(%Surface{default_screen: default_screen, screens: screens}) do
    Enum.find(screens, &(&1.id == default_screen))
  end

  defp put_variant(%Surface{} = definition, profile, %Surface.Variant{} = variant) do
    %{
      definition
      | screens: Enum.map(definition.screens, &put_variant_in_screen(&1, profile, variant))
    }
  end

  defp put_variant_in_screen(%Surface.Screen{} = screen, profile, variant) do
    if Map.has_key?(screen.variants, profile) do
      %{screen | variants: Map.put(screen.variants, profile, variant)}
    else
      screen
    end
  end

  defp update_zone_map(template, zones, params) do
    Enum.into(zones, %{}, fn {zone_id, zone} ->
      zone_params = Map.get(params, Atom.to_string(zone_id), %{})

      updated_area = %{
        col: int_param(zone_params, "col", zone.area.col),
        row: int_param(zone_params, "row", zone.area.row),
        col_span: int_param(zone_params, "col_span", zone.area.col_span),
        row_span: int_param(zone_params, "row_span", zone.area.row_span)
      }

      {zone_id, %{zone | area: updated_area, node: update_zone_node(template, zone, zone_params)}}
    end)
  end

  defp update_zone_node(_template, zone, params) do
    case zone.node do
      %Surface.Widget{} = widget ->
        type = params |> Map.get("type", widget.type) |> parse_atom(widget.type)

        binding =
          params |> Map.get("binding", widget.binding) |> parse_optional_atom(widget.binding)

        option_source =
          if type == widget.type, do: widget, else: %Surface.Widget{widget | options: %{}}

        options = widget_options_for_type(type, params, option_source)
        %Surface.Widget{widget | type: type, binding: binding, options: options}

      node ->
        node
    end
  end

  defp widget_options_for_type(:status_tile, params, widget) do
    widget.options
    |> maybe_put_string(:label, Map.get(params, "label"))
    |> maybe_put_atomish(:field, Map.get(params, "field"))
  end

  defp widget_options_for_type(:value_grid, params, widget) do
    case parse_fields(Map.get(params, "fields")) do
      [] -> widget.options
      fields -> Map.merge(widget.options, %{fields: fields})
    end
  end

  defp widget_options_for_type(:fault_list, params, widget) do
    case parse_positive_int(Map.get(params, "limit")) do
      nil -> widget.options
      limit -> Map.merge(widget.options, %{limit: limit})
    end
  end

  defp widget_options_for_type(:machine_summary_card, params, widget) do
    case parse_non_negative_int(Map.get(params, "index")) do
      nil -> widget.options
      index -> Map.merge(widget.options, %{index: index})
    end
  end

  defp widget_options_for_type(_type, _params, widget), do: widget.options

  defp int_param(params, key, fallback) do
    case Integer.parse(to_string(Map.get(params, key, fallback))) do
      {value, ""} when value > 0 -> value
      _ -> fallback
    end
  end

  defp parse_positive_int(nil), do: nil

  defp parse_positive_int(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_non_negative_int(nil), do: nil

  defp parse_non_negative_int(value) do
    case Integer.parse(to_string(value)) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> nil
    end
  end

  defp parse_fields(nil), do: []

  defp parse_fields(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&atomish_value/1)
  end

  defp maybe_put_string(options, _key, nil), do: options
  defp maybe_put_string(options, _key, ""), do: options
  defp maybe_put_string(options, key, value), do: Map.put(options, key, value)

  defp maybe_put_atomish(options, _key, nil), do: options
  defp maybe_put_atomish(options, _key, ""), do: options
  defp maybe_put_atomish(options, key, value), do: Map.put(options, key, atomish_value(value))

  defp atomish_value(value) when is_atom(value), do: value

  defp atomish_value(value) do
    try do
      String.to_existing_atom(to_string(value))
    rescue
      ArgumentError -> to_string(value)
    end
  end

  defp parse_atom(value, _fallback) when is_atom(value), do: value

  defp parse_atom(value, fallback) do
    try do
      String.to_existing_atom(to_string(value))
    rescue
      ArgumentError -> fallback
    end
  end

  defp parse_optional_atom(nil, fallback), do: fallback
  defp parse_optional_atom("", _fallback), do: nil
  defp parse_optional_atom(value, fallback), do: parse_atom(value, fallback)

  defp binding_list(%Surface{bindings: bindings}), do: bindings

  defp bindings_for_zone(nil, _zone), do: []

  defp bindings_for_zone(%Surface{} = definition, zone) do
    current_binding = binding_for_zone(definition, zone)
    widget_type = zone_widget_type(zone)

    compatible =
      definition
      |> binding_list()
      |> Enum.filter(&binding_compatible_with_widget?(widget_type, &1))

    if is_nil(current_binding) or Enum.any?(compatible, &(&1.name == current_binding.name)) do
      compatible
    else
      [current_binding | compatible]
    end
  end

  defp binding_label(%Surface.BindingRef{name: name}), do: to_string(name)

  defp binding_detail(nil, _zone), do: "No binding information available."

  defp binding_detail(%Surface{} = definition, zone) do
    cond do
      grouped_zone?(zone) ->
        "This zone currently uses a grouped layout. Switch to Source to edit its child widgets."

      true ->
        case binding_for_zone(definition, zone) do
          %Surface.BindingRef{source: source} -> describe_binding_source(source)
          nil -> "This zone is not connected to a binding."
        end
    end
  end

  defp binding_for_zone(%Surface{} = definition, zone) do
    binding_name = zone_binding(zone)

    Enum.find(binding_list(definition), fn binding ->
      binding.name == binding_name
    end)
  end

  defp grouped_zone?(%{node: %Surface.Group{}}), do: true
  defp grouped_zone?(_zone), do: false

  defp zone_widget_editable?(%{node: %Surface.Widget{}}), do: true
  defp zone_widget_editable?(_zone), do: false

  defp describe_binding_source({:machine_status, machine}),
    do: "Connected to machine status for #{machine}."

  defp describe_binding_source({:machine_alarm_summary, machine}),
    do: "Connected to machine alarms for #{machine}."

  defp describe_binding_source({:machine_skills, machine}),
    do: "Connected to the available skills for #{machine}."

  defp describe_binding_source({:machine_summary, machine}),
    do: "Connected to the machine summary for #{machine}."

  defp describe_binding_source({:machine_events, machine}),
    do: "Connected to recent machine events for #{machine}."

  defp describe_binding_source({:topology_runtime_summary, topology}),
    do: "Connected to the active topology runtime summary for #{topology}."

  defp describe_binding_source({:topology_alarm_summary, topology}),
    do: "Connected to topology alarms for #{topology}."

  defp describe_binding_source({:topology_attention_lane, topology}),
    do: "Connected to the topology attention lane for #{topology}."

  defp describe_binding_source({:topology_orchestration_status, topology}),
    do: "Connected to operator orchestration status for #{topology}."

  defp describe_binding_source({:topology_procedure_catalog, topology}),
    do: "Connected to the operator procedure catalog for #{topology}."

  defp describe_binding_source({:topology_machine_registry, topology}),
    do: "Connected to the machine registry for #{topology}."

  defp describe_binding_source({:topology_event_stream, topology}),
    do: "Connected to recent topology events for #{topology}."

  defp describe_binding_source({:topology_links, topology}),
    do: "Connected to topology navigation links for #{topology}."

  defp describe_binding_source({:static_links, _links}),
    do: "Connected to static navigation links."

  defp describe_binding_source(source), do: "Connected to #{inspect(source)}."

  defp ordered_variant_zones(%Surface.Variant{} = variant) do
    variant.zones
    |> Map.values()
    |> Enum.sort_by(fn zone -> {zone.area.row, zone.area.col, zone.id} end)
  end

  defp zone_title(zone_id) do
    zone_id
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp zone_area_label(zone) do
    "Area #{zone.area.col},#{zone.area.row}  Span #{zone.area.col_span}x#{zone.area.row_span}"
  end

  defp widget_type_label(widget_type) do
    widget_type
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp editable_widget_options(nil, _zone_id), do: []

  defp editable_widget_options(%Surface{template: template}, zone_id) do
    template
    |> Surface.allowed_widget_types(zone_id)
    |> Enum.filter(&(&1 in @preview_supported_widgets))
  end

  defp binding_compatible_with_widget?(widget_type, %Surface.BindingRef{source: source}) do
    source_family = binding_source_family(source)

    case compatible_binding_families(widget_type) do
      :any -> true
      families -> source_family in families
    end
  end

  defp compatible_binding_families(:summary_strip), do: [:topology_runtime_summary]

  defp compatible_binding_families(:alarm_strip),
    do: [:topology_alarm_summary, :machine_alarm_summary]

  defp compatible_binding_families(:procedure_panel), do: [:topology_orchestration_status]
  defp compatible_binding_families(:attention_lane), do: [:topology_attention_lane]
  defp compatible_binding_families(:machine_grid), do: [:topology_machine_registry]
  defp compatible_binding_families(:event_ticker), do: [:topology_event_stream, :machine_events]
  defp compatible_binding_families(:quick_links), do: [:topology_links, :static_links]
  defp compatible_binding_families(:skill_button_group), do: [:machine_skills]

  defp compatible_binding_families(:machine_summary_card),
    do: [:topology_machine_registry, :machine_summary]

  defp compatible_binding_families(:status_tile), do: :any
  defp compatible_binding_families(:value_grid), do: :any

  defp compatible_binding_families(:fault_list),
    do: [:topology_alarm_summary, :machine_alarm_summary, :topology_event_stream, :machine_events]

  defp compatible_binding_families(:navigation_buttons), do: [:topology_links, :static_links]
  defp compatible_binding_families(_widget_type), do: :any

  defp binding_source_family({:machine_status, _}), do: :machine_status
  defp binding_source_family({:machine_alarm_summary, _}), do: :machine_alarm_summary
  defp binding_source_family({:machine_skills, _}), do: :machine_skills
  defp binding_source_family({:machine_summary, _}), do: :machine_summary
  defp binding_source_family({:machine_events, _}), do: :machine_events
  defp binding_source_family({:topology_runtime_summary, _}), do: :topology_runtime_summary
  defp binding_source_family({:topology_alarm_summary, _}), do: :topology_alarm_summary
  defp binding_source_family({:topology_attention_lane, _}), do: :topology_attention_lane

  defp binding_source_family({:topology_orchestration_status, _}),
    do: :topology_orchestration_status

  defp binding_source_family({:topology_procedure_catalog, _}), do: :topology_procedure_catalog
  defp binding_source_family({:topology_machine_registry, _}), do: :topology_machine_registry
  defp binding_source_family({:topology_event_stream, _}), do: :topology_event_stream
  defp binding_source_family({:topology_links, _}), do: :topology_links
  defp binding_source_family({:static_links, _}), do: :static_links
  defp binding_source_family(source), do: source

  defp zone_widget_type(%{node: %Surface.Widget{type: type}}), do: type
  defp zone_widget_type(%{node: %Surface.Group{mode: mode}}), do: mode

  defp zone_binding(%{node: %Surface.Widget{binding: binding}}), do: binding
  defp zone_binding(_zone), do: nil

  defp zone_option(%{node: %Surface.Widget{options: options}}, key) do
    case Map.get(options, key) do
      nil -> nil
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end
  end

  defp zone_option(_zone, _key), do: nil

  defp zone_fields(%{node: %Surface.Widget{options: %{fields: fields}}}) when is_list(fields) do
    Enum.map_join(fields, ",", fn
      value when is_atom(value) -> Atom.to_string(value)
      value -> to_string(value)
    end)
  end

  defp zone_fields(_zone), do: nil

  defp zone_supports_label?(%{node: %Surface.Widget{type: :status_tile}}), do: true
  defp zone_supports_label?(_zone), do: false

  defp zone_supports_field?(%{node: %Surface.Widget{type: :status_tile}}), do: true
  defp zone_supports_field?(_zone), do: false

  defp zone_supports_fields?(%{node: %Surface.Widget{type: :value_grid}}), do: true
  defp zone_supports_fields?(_zone), do: false

  defp zone_supports_limit?(%{node: %Surface.Widget{type: :fault_list}}), do: true
  defp zone_supports_limit?(_zone), do: false

  defp zone_supports_index?(%{node: %Surface.Widget{type: :machine_summary_card}}), do: true
  defp zone_supports_index?(_zone), do: false

  defp zone_has_options?(zone) do
    zone_supports_label?(zone) or zone_supports_field?(zone) or zone_supports_fields?(zone) or
      zone_supports_limit?(zone) or zone_supports_index?(zone)
  end

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}

  defp readonly_surface(socket) do
    assign(
      socket,
      :studio_feedback,
      feedback(
        :warning,
        "Workspace Session",
        "Studio edits the shared workspace session directly."
      )
    )
  end

  defp profile_button_classes(true), do: "app-button"
  defp profile_button_classes(false), do: "app-button-secondary"

  defp input_classes, do: "app-input w-full"
  defp select_classes, do: "app-input w-full"
  defp textarea_classes, do: "app-input w-full"
  defp dsl_textarea_classes, do: "app-input min-h-[42rem] w-full font-mono text-[13px] leading-6"
end
