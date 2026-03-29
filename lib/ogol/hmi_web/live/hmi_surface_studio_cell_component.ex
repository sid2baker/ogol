defmodule Ogol.HMIWeb.HmiSurfaceStudioCellComponent do
  use Ogol.HMIWeb, :live_component

  alias Ogol.HMI.{Surface, SurfaceCompiler, SurfaceDeployment, SurfaceDraftStore, SurfacePrinter}
  alias Ogol.HMI.Surface.Template
  alias Ogol.HMI.SurfaceCompiler.Analysis
  alias Ogol.HMI.StudioWorkspace.Cell, as: WorkspaceCell
  alias Ogol.HMIWeb.Components.{OverviewSurface, StudioCell}
  alias Ogol.Studio.Cell, as: StudioCellState
  alias Ogol.Studio.HmiSurfaceCell

  @preview_supported_widgets [
    :summary_strip,
    :alarm_strip,
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
  def update(%{cell: %WorkspaceCell{} = cell} = assigns, socket) do
    draft =
      SurfaceDraftStore.ensure_definition_draft(cell.surface_id, cell.definition,
        source_module: cell.source_module
      )

    analysis = SurfaceCompiler.analyze(draft.source)
    current_assignment = SurfaceDeployment.default_assignment()

    selected_profile =
      resolve_selected_profile(
        socket.assigns[:selected_profile],
        analysis.runtime,
        current_assignment
      )

    selected_assignment_version =
      selected_assignment_version(
        draft,
        current_assignment,
        socket.assigns[:selected_assignment_version]
      )

    requested_view =
      socket.assigns[:requested_view] || HmiSurfaceCell.default_requested_view(analysis)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:cell, cell)
     |> assign(:surface_draft, draft)
     |> assign(:requested_view, requested_view)
     |> assign(:selected_profile, selected_profile)
     |> assign(:selected_assignment_version, selected_assignment_version)
     |> assign(:studio_feedback, socket.assigns[:studio_feedback])
     |> assign(:current_assignment, current_assignment)
     |> assign_analysis(draft.source, analysis)}
  end

  @impl true
  def handle_event("select_view", %{"view" => view}, socket) do
    requested_view =
      view
      |> String.to_existing_atom()
      |> then(fn parsed -> if parsed in [:visual, :source], do: parsed, else: :source end)

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
    draft =
      SurfaceDraftStore.save_source(socket.assigns.cell.surface_id, source,
        source_module: socket.assigns.cell.source_module
      )

    analysis = SurfaceCompiler.analyze(draft.source)

    {:noreply,
     socket
     |> assign(:surface_draft, draft)
     |> assign(:studio_feedback, nil)
     |> assign_analysis(draft.source, analysis)}
  end

  def handle_event("request_transition", %{"transition" => "compile"}, socket) do
    if SurfaceCompiler.ready?(socket.assigns.source_analysis) do
      draft =
        SurfaceDraftStore.compile(
          socket.assigns.cell.surface_id,
          socket.assigns.source_analysis.definition,
          socket.assigns.source_analysis.runtime
        )

      {:noreply,
       socket
       |> assign(:surface_draft, draft)
       |> assign(
         :studio_feedback,
         feedback(:good, "Compiled", "#{draft.compiled_version} ready for deployment.")
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

  def handle_event("request_transition", %{"transition" => "deploy"}, socket) do
    case socket.assigns.surface_draft.compiled_runtime do
      %Surface.Runtime{} ->
        draft = SurfaceDraftStore.deploy(socket.assigns.cell.surface_id)

        {:noreply,
         socket
         |> assign(:surface_draft, draft)
         |> assign(:selected_assignment_version, draft.deployed_version)
         |> assign(
           :studio_feedback,
           feedback(
             :good,
             "Deployed",
             "#{draft.deployed_version} published for runtime assignment."
           )
         )}

      _ ->
        {:noreply,
         assign(
           socket,
           :studio_feedback,
           feedback(:danger, "Deploy blocked", "Compile a valid HMI surface before deploying it.")
         )}
    end
  end

  def handle_event("request_transition", %{"transition" => "assign_panel"}, socket) do
    case socket.assigns.surface_draft.deployed_version do
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
            socket.assigns.cell.surface_id,
            version: socket.assigns.selected_assignment_version
          )

        send(self(), {:hmi_assignment_changed})

        {:noreply,
         socket
         |> assign(:current_assignment, assignment)
         |> assign(:selected_assignment_version, assignment.surface_version)
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

  def handle_event(
        "select_assignment_version",
        %{"assignment" => %{"version" => version}},
        socket
      ) do
    version =
      if version in published_versions(socket.assigns.surface_draft) do
        version
      else
        socket.assigns.selected_assignment_version
      end

    {:noreply, assign(socket, :selected_assignment_version, version)}
  end

  def handle_event("change_metadata", %{"surface" => params}, socket) do
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

  def handle_event("change_zone_config", %{"zones" => params}, socket) do
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

  @impl true
  def render(assigns) do
    surface_facts = HmiSurfaceCell.facts_from_assigns(assigns)

    assigns =
      assign(assigns, :surface_cell, StudioCellState.derive(HmiSurfaceCell, surface_facts))

    ~H"""
    <div id={"hmi-cell-#{@cell.surface_id}"}>
      <StudioCell.cell>
        <:actions>
          <StudioCell.action_button
            :for={action <- @surface_cell.actions}
            type="button"
            phx-click="request_transition"
            phx-target={@myself}
            phx-value-transition={action.id}
            variant={action.variant}
            disabled={!action.enabled?}
            title={action.disabled_reason}
          >
            {action.label}
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
          <div class="space-y-4">
        <section class="space-y-2">
          <p class="app-kicker">{cell_kind(@cell.kind)}</p>
          <h2 class="text-2xl font-semibold tracking-tight text-[var(--app-text)]">{@cell.title}</h2>
          <p class="max-w-4xl text-sm leading-6 text-[var(--app-text-muted)]">{@cell.summary}</p>
        </section>

        <section class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(18rem,22rem)]">
          <div class="app-panel px-5 py-5">
            <p class="app-kicker">Deployment</p>
            <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Published runtime</h3>

            <div class="mt-4 grid gap-3 sm:grid-cols-2">
              <div class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-3">
                <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Surface Id</p>
                <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">{@cell.surface_id}</p>
              </div>
              <div class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-3">
                <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Assigned</p>
                <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">
                  {assignment_label(@current_assignment, @cell.surface_id)}
                </p>
              </div>
            </div>
          </div>

          <div class="app-panel px-5 py-5">
            <p class="app-kicker">Runtime Version</p>
            <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Panel assignment target</h3>

            <form :if={published_versions(@surface_draft) != []} phx-change="select_assignment_version" phx-target={@myself} class="mt-4 space-y-2">
              <label class="space-y-2">
                <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Version</span>
                <select name="assignment[version]" class={select_classes()}>
                  <option
                    :for={version <- published_versions(@surface_draft)}
                    value={version}
                    selected={version == @selected_assignment_version}
                  >
                    {version}
                  </option>
                </select>
              </label>
            </form>

            <p :if={published_versions(@surface_draft) == []} class="mt-4 text-sm leading-6 text-[var(--app-text-muted)]">
              Compile and deploy this surface before assigning a runtime version.
            </p>
          </div>
        </section>

        <div
          :if={@surface_cell.selected_view == :visual}
          class="grid gap-4 2xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]"
        >
          <section class="app-panel overflow-hidden">
            <div class="flex items-center justify-between border-b border-[var(--app-border)] px-5 py-4">
              <div>
                <p class="app-kicker">Preview</p>
                <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">Compiled runtime surface</h3>
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

          <section class="space-y-4">
            <section class="app-panel px-5 py-5">
              <p class="app-kicker">Visual Editor</p>
              <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Surface metadata</h3>

              <form :if={@surface_definition} phx-change="change_metadata" phx-target={@myself} class="mt-4 grid gap-4">
                <label class="space-y-1.5">
                  <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Title</span>
                  <input type="text" name="surface[title]" value={@surface_definition.title} class={input_classes()} />
                </label>

                <label class="space-y-1.5">
                  <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Summary</span>
                  <textarea name="surface[summary]" rows="4" class={textarea_classes()}>{@surface_definition.summary}</textarea>
                </label>
              </form>
            </section>

            <section class="app-panel px-5 py-5">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <p class="app-kicker">Zone Configuration</p>
                  <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Placement and node config</h3>
                </div>

                <span class="studio-state border-[var(--app-border)] bg-[var(--app-surface-alt)] text-[var(--app-text-muted)]">
                  {@selected_profile || "no profile"}
                </span>
              </div>

              <form :if={@surface_variant} phx-change="change_zone_config" phx-target={@myself} class="mt-4 overflow-x-auto">
                <table class="min-w-full border-collapse text-sm">
                  <thead>
                    <tr class="border-b border-[var(--app-border)] text-left font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
                      <th class="py-2 pr-3">Zone</th>
                      <th class="py-2 pr-3">Widget</th>
                      <th class="py-2 pr-3">Binding</th>
                      <th class="py-2 pr-3">Options</th>
                      <th class="py-2 pr-3">Col</th>
                      <th class="py-2 pr-3">Row</th>
                      <th class="py-2 pr-3">Col Span</th>
                      <th class="py-2">Row Span</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={zone <- ordered_variant_zones(@surface_variant)} class="border-b border-[var(--app-border)]/70">
                      <td class="py-3 pr-3 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text)]">{zone.id}</td>
                      <td class="py-3 pr-3">
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
                            {widget_type}
                          </option>
                        </select>
                      </td>
                      <td class="py-3 pr-3">
                        <select name={"zones[#{zone.id}][binding]"} class={select_classes()} disabled={is_nil(@surface_definition)}>
                          <option value="">none</option>
                          <option
                            :for={binding <- binding_list(@surface_definition)}
                            value={binding.name}
                            selected={zone_binding(zone) == binding.name}
                          >
                            {binding.name}
                          </option>
                        </select>
                      </td>
                      <td class="py-3 pr-3">
                        <div class="grid gap-2">
                          <input
                            :if={zone_supports_label?(zone)}
                            type="text"
                            name={"zones[#{zone.id}][label]"}
                            value={zone_option(zone, :label)}
                            placeholder="Label"
                            class={mini_text_input_classes()}
                          />
                          <input
                            :if={zone_supports_field?(zone)}
                            type="text"
                            name={"zones[#{zone.id}][field]"}
                            value={zone_option(zone, :field)}
                            placeholder="Field"
                            class={mini_text_input_classes()}
                          />
                          <input
                            :if={zone_supports_fields?(zone)}
                            type="text"
                            name={"zones[#{zone.id}][fields]"}
                            value={zone_fields(zone)}
                            placeholder="field_a,field_b"
                            class={mini_text_input_classes()}
                          />
                          <input
                            :if={zone_supports_limit?(zone)}
                            type="number"
                            name={"zones[#{zone.id}][limit]"}
                            value={zone_option(zone, :limit)}
                            placeholder="Limit"
                            class={mini_input_classes()}
                          />
                          <input
                            :if={zone_supports_index?(zone)}
                            type="number"
                            name={"zones[#{zone.id}][index]"}
                            value={zone_option(zone, :index)}
                            placeholder="Index"
                            class={mini_input_classes()}
                          />
                        </div>
                      </td>
                      <td class="py-3 pr-3"><input type="number" name={"zones[#{zone.id}][col]"} value={zone.area.col} class={mini_input_classes()} /></td>
                      <td class="py-3 pr-3"><input type="number" name={"zones[#{zone.id}][row]"} value={zone.area.row} class={mini_input_classes()} /></td>
                      <td class="py-3 pr-3"><input type="number" name={"zones[#{zone.id}][col_span]"} value={zone.area.col_span} class={mini_input_classes()} /></td>
                      <td class="py-3"><input type="number" name={"zones[#{zone.id}][row_span]"} value={zone.area.row_span} class={mini_input_classes()} /></td>
                    </tr>
                  </tbody>
                </table>
              </form>
            </section>
          </section>
        </div>

        <section :if={@surface_cell.selected_view == :source} class="app-panel overflow-hidden">
          <div class="border-b border-[var(--app-border)] px-5 py-4">
            <p class="app-kicker">Source</p>
            <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Source of truth</h3>
          </div>

          <form phx-change="change_source" phx-target={@myself} class="p-4">
            <textarea name="draft[source]" rows="32" class={dsl_textarea_classes()} phx-debounce="400">{@draft_source}</textarea>
          </form>
        </section>
          </div>
        </:body>
      </StudioCell.cell>
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
    source = SurfacePrinter.print(definition, module: socket.assigns.surface_draft.source_module)
    analysis = SurfaceCompiler.analyze(source)

    if SurfaceCompiler.ready?(analysis) do
      draft =
        SurfaceDraftStore.save_source(socket.assigns.cell.surface_id, source,
          source_module: socket.assigns.surface_draft.source_module
        )

      socket
      |> assign(:surface_draft, draft)
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

  defp selected_assignment_version(draft, assignment, current_selection) do
    cond do
      current_selection in published_versions(draft) ->
        current_selection

      assignment.surface_id == draft.surface_id and assignment.surface_version ->
        assignment.surface_version

      draft.deployed_version ->
        draft.deployed_version

      true ->
        published_versions(draft) |> List.first()
    end
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

  defp binding_list(nil), do: []
  defp binding_list(%Surface{bindings: bindings}), do: bindings

  defp published_versions(draft), do: SurfaceDraftStore.published_versions(draft)

  defp ordered_variant_zones(%Surface.Variant{} = variant) do
    variant.zones
    |> Map.values()
    |> Enum.sort_by(fn zone -> {zone.area.row, zone.area.col, zone.id} end)
  end

  defp editable_widget_options(nil, _zone_id), do: []

  defp editable_widget_options(%Surface{template: template}, zone_id) do
    template
    |> Surface.allowed_widget_types(zone_id)
    |> Enum.filter(&(&1 in @preview_supported_widgets))
  end

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

  defp assignment_label(assignment, surface_id) do
    if assignment.surface_id == surface_id do
      "#{assignment.panel_id} @ #{assignment.surface_version || "draft"}"
    else
      "not assigned"
    end
  end

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}

  defp cell_kind(:overview), do: "Overview HMI"
  defp cell_kind(:station), do: "Station HMI"
  defp cell_kind(_other), do: "HMI"

  defp profile_button_classes(true), do: "app-button"
  defp profile_button_classes(false), do: "app-button-secondary"

  defp input_classes, do: "app-input w-full"
  defp mini_input_classes, do: "app-input w-20"
  defp mini_text_input_classes, do: "app-input w-36"
  defp select_classes, do: "app-input w-full"
  defp textarea_classes, do: "app-input w-full"
  defp dsl_textarea_classes, do: "app-input min-h-[42rem] w-full font-mono text-[13px] leading-6"
end
