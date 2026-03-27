defmodule Ogol.HMIWeb.HmiStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.{Surface, SurfaceCompiler, SurfaceDeployment, SurfaceDraftStore, SurfacePrinter}
  alias Ogol.HMI.SurfaceCompiler.Analysis
  alias Ogol.HMI.Surface.Template
  alias Ogol.HMIWeb.Components.OverviewSurface

  @editor_modes [:visual, :dsl, :split]
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
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "HMI Studio")
     |> assign(
       :page_summary,
       "Template-first runtime surface authoring with canonical DSL, compile-time render plans, published versions, and explicit panel assignment."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :hmis)
     |> assign(:editor_modes, @editor_modes)
     |> assign(:editor_mode, :split)
     |> assign(:selected_profile, nil)
     |> assign(:studio_feedback, nil)
     |> load_surface(params_surface_id(nil))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_surface(socket, params_surface_id(params["surface_id"]))}
  end

  @impl true
  def handle_event("set_editor_mode", %{"mode" => mode}, socket) do
    mode =
      mode
      |> String.to_existing_atom()
      |> then(fn mode -> if mode in @editor_modes, do: mode, else: :split end)

    {:noreply, assign(socket, :editor_mode, mode)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("select_profile", %{"profile" => profile}, socket) do
    profile =
      try do
        String.to_existing_atom(profile)
      rescue
        ArgumentError -> socket.assigns.selected_profile
      end

    {:noreply, assign(socket, :selected_profile, profile)}
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    analysis = SurfaceCompiler.analyze(source)

    {:noreply,
     socket
     |> assign(:studio_feedback, nil)
     |> assign_analysis(source, analysis)}
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

  def handle_event("save_draft", _params, socket) do
    draft = SurfaceDraftStore.save_source(socket.assigns.surface_id, socket.assigns.draft_source)

    {:noreply,
     socket
     |> assign(:persisted_source, draft.source)
     |> assign(:surface_draft, draft)
     |> assign(:dirty?, false)
     |> assign(
       :studio_feedback,
       feedback(
         :ok,
         "Draft saved",
         "DSL draft persisted. Compile and deploy remain separate steps."
       )
     )}
  end

  def handle_event("compile_draft", _params, socket) do
    if SurfaceCompiler.ready?(socket.assigns.source_analysis) do
      draft =
        SurfaceDraftStore.compile(
          socket.assigns.surface_id,
          socket.assigns.draft_source,
          socket.assigns.source_analysis.definition,
          socket.assigns.source_analysis.runtime
        )

      {:noreply,
       socket
       |> assign(:surface_draft, draft)
       |> assign(
         :studio_feedback,
         feedback(:ok, "Compiled", "Runtime render plan prepared as #{draft.compiled_version}.")
       )}
    else
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(
           :error,
           "Compile blocked",
           "Resolve parse or validation errors before compiling this surface."
         )
       )}
    end
  end

  def handle_event("deploy_draft", _params, socket) do
    draft = socket.assigns.surface_draft

    if draft.compiled_runtime do
      updated = SurfaceDraftStore.deploy(socket.assigns.surface_id)

      {:noreply,
       socket
       |> assign(:surface_draft, updated)
       |> assign(:selected_assignment_version, updated.deployed_version)
       |> assign(
         :studio_feedback,
         feedback(
           :ok,
           "Deployed",
           "Compiled surface #{updated.deployed_version} is now published for runtime assignment."
         )
       )}
    else
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(:error, "Deploy blocked", "Compile a valid surface version before deployment.")
       )}
    end
  end

  def handle_event("change_metadata", %{"surface" => params}, socket) do
    with %Surface{} = definition <- socket.assigns.surface_definition do
      updated =
        definition
        |> Map.put(:title, Map.get(params, "title", definition.title))
        |> Map.put(:summary, Map.get(params, "summary", definition.summary))

      {:noreply, apply_visual_update(socket, updated)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("assign_panel", _params, socket) do
    if socket.assigns.surface_draft.deployed_version do
      version = socket.assigns.selected_assignment_version

      assignment =
        SurfaceDeployment.assign_panel(
          socket.assigns.deployment.panel_id,
          socket.assigns.surface_id,
          version: version
        )

      {:noreply,
       socket
       |> assign(:deployment, assignment)
       |> assign(:current_assignment, assignment)
       |> assign(:selected_assignment_version, assignment.surface_version)
       |> assign(
         :studio_feedback,
         feedback(
           :ok,
           "Assigned",
           "Panel #{assignment.panel_id} now opens #{assignment.surface_id}@#{assignment.surface_version} by default."
         )
       )}
    else
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(
           :error,
           "Assignment blocked",
           "Deploy a surface version before assigning it to a runtime panel."
         )
       )}
    end
  end

  def handle_event("change_zone_config", %{"zones" => params}, socket) do
    with %Surface{} = definition <- socket.assigns.surface_definition,
         profile when not is_nil(profile) <- socket.assigns.selected_profile,
         %Surface.Variant{} = variant <- current_variant(definition, profile) do
      updated_variant =
        %{variant | zones: update_zone_map(definition.template, variant.zones, params)}

      updated_definition = put_variant(definition, profile, updated_variant)

      {:noreply, apply_visual_update(socket, updated_definition)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_22rem]">
      <div class="space-y-4">
        <section class="app-panel px-5 py-5">
          <div class="flex flex-col gap-4 2xl:flex-row 2xl:items-start 2xl:justify-between">
            <div class="max-w-4xl">
              <p class="app-kicker">Runtime Surface Artifact</p>
              <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
                {@surface_title}
              </h2>
              <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                Author canonical HMI DSL artifacts, compile normalized render plans, publish explicit versions, and assign them to runtime panels deliberately.
              </p>
            </div>

            <div class="flex flex-wrap gap-2">
              <button
                :for={mode <- @editor_modes}
                type="button"
                phx-click="set_editor_mode"
                phx-value-mode={mode}
                class={mode_button_classes(@editor_mode == mode)}
              >
                {mode_label(mode)}
              </button>
            </div>
          </div>

          <div class="mt-4 flex flex-col gap-3 xl:flex-row xl:items-center xl:justify-between">
            <div class="flex flex-wrap gap-2">
              <.surface_chip label="Artifact" value={@surface_id} />
              <.surface_chip label="State" value={editor_state_label(@source_analysis.classification)} />
              <.surface_chip label="Dirty" value={if(@dirty?, do: "yes", else: "no")} />
              <.surface_chip label="Compiled" value={@surface_draft.compiled_version || "none"} />
              <.surface_chip label="Deployed" value={@surface_draft.deployed_version || "none"} />
              <.surface_chip label="Target Version" value={@selected_assignment_version || "none"} />
              <.surface_chip label="Assigned Panel" value={assignment_summary(@current_assignment)} />
            </div>

            <div class="flex flex-wrap gap-2">
              <button type="button" phx-click="save_draft" class={action_button_classes(:neutral)}>
                Save Draft
              </button>
              <button type="button" phx-click="compile_draft" class={action_button_classes(:info)}>
                Compile
              </button>
              <button type="button" phx-click="deploy_draft" class={action_button_classes(:good)}>
                Deploy
              </button>
              <button type="button" phx-click="assign_panel" class={action_button_classes(:warn)}>
                Assign Panel
              </button>
            </div>
          </div>

          <div :if={@studio_feedback} class={["mt-4 border px-4 py-3", feedback_classes(@studio_feedback.tone)]}>
            <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
              <div>
                <p class="app-kicker">Studio Feedback</p>
                <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">{@studio_feedback.title}</p>
              </div>
              <p class="max-w-3xl text-sm leading-6 text-[var(--app-text-muted)] sm:text-right">
                {@studio_feedback.detail}
              </p>
            </div>
          </div>
        </section>

        <div :if={@editor_mode in [:visual, :split]} class={editor_grid_classes(@editor_mode)}>
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
                This draft is not currently in a visually editable state. Fix diagnostics in the DSL view to restore the compiled preview.
              </p>
            </div>
          </section>

          <section :if={@editor_mode in [:visual, :split]} class="space-y-4">
            <section class="app-panel px-5 py-5">
              <p class="app-kicker">Visual Editor</p>
              <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Surface metadata</h3>

              <form :if={@surface_definition} phx-change="change_metadata" class="mt-4 grid gap-4">
                <label class="space-y-1.5">
                  <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Title</span>
                  <input
                    type="text"
                    name="surface[title]"
                    value={@surface_definition.title}
                    class={input_classes()}
                  />
                </label>

                <label class="space-y-1.5">
                  <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Summary</span>
                  <textarea
                    name="surface[summary]"
                    rows="4"
                    class={textarea_classes()}
                  >{@surface_definition.summary}</textarea>
                </label>
              </form>

              <div
                :if={is_nil(@surface_definition)}
                class="mt-4 border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4 text-sm leading-6 text-[var(--app-text-muted)]"
              >
                Visual metadata editing is available only when the DSL compiles into a managed HMI surface definition.
              </div>
            </section>

            <section class="app-panel px-5 py-5">
              <div class="flex items-center justify-between gap-3">
                <div>
                  <p class="app-kicker">Zone Configuration</p>
                  <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Placement and node config for {@selected_profile}</h3>
                </div>

                <span class="studio-state border-[var(--app-border)] bg-[var(--app-surface-alt)] text-[var(--app-text-muted)]">
                  {@selected_profile || "no profile"}
                </span>
              </div>

              <form :if={@surface_variant} phx-change="change_zone_config" class="mt-4 overflow-x-auto">
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
                      <td class="py-3 pr-3 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text)]">
                        {zone.id}
                      </td>
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
                          <p
                            :if={
                              not zone_supports_label?(zone) and not zone_supports_field?(zone) and
                                not zone_supports_fields?(zone) and not zone_supports_limit?(zone) and
                                not zone_supports_index?(zone)
                            }
                            class="text-[11px] text-[var(--app-text-dim)]"
                          >
                            fixed node options
                          </p>
                        </div>
                      </td>
                      <td class="py-3 pr-3">
                        <input type="number" name={"zones[#{zone.id}][col]"} value={zone.area.col} class={mini_input_classes()} />
                      </td>
                      <td class="py-3 pr-3">
                        <input type="number" name={"zones[#{zone.id}][row]"} value={zone.area.row} class={mini_input_classes()} />
                      </td>
                      <td class="py-3 pr-3">
                        <input type="number" name={"zones[#{zone.id}][col_span]"} value={zone.area.col_span} class={mini_input_classes()} />
                      </td>
                      <td class="py-3">
                        <input type="number" name={"zones[#{zone.id}][row_span]"} value={zone.area.row_span} class={mini_input_classes()} />
                      </td>
                    </tr>
                  </tbody>
                </table>
              </form>

              <div
                :if={is_nil(@surface_variant)}
                class="mt-4 border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4 text-sm leading-6 text-[var(--app-text-muted)]"
              >
                Visual zone editing is available only when the current draft compiles successfully.
              </div>
            </section>
          </section>
        </div>

        <section :if={@editor_mode == :dsl} class="app-panel overflow-hidden">
          <div class="border-b border-[var(--app-border)] px-5 py-4">
            <p class="app-kicker">Canonical DSL</p>
            <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Source of truth</h3>
          </div>

          <form phx-change="change_source" class="p-4">
            <textarea
              name="draft[source]"
              rows="32"
              class={dsl_textarea_classes()}
              phx-debounce="400"
            >{@draft_source}</textarea>
          </form>
        </section>

        <section :if={@editor_mode == :split} class="app-panel overflow-hidden">
          <div class="border-b border-[var(--app-border)] px-5 py-4">
            <p class="app-kicker">Canonical DSL</p>
            <h3 class="mt-2 text-lg font-semibold text-[var(--app-text)]">Source of truth</h3>
          </div>

          <form phx-change="change_source" class="p-4">
            <textarea
              name="draft[source]"
              rows="32"
              class={dsl_textarea_classes()}
              phx-debounce="400"
            >{@draft_source}</textarea>
          </form>
        </section>
      </div>

      <aside class="space-y-4">
        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Surface Library</p>
          <div class="mt-4 space-y-3">
            <.link
              :for={draft <- @surface_library}
              navigate={~p"/studio/hmis/#{draft.surface_id}"}
              class={[
                "block border px-4 py-4 transition",
                if(
                  draft.surface_id == @surface_id,
                  do:
                    "border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]",
                  else:
                    "border-[var(--app-border)] bg-[var(--app-surface-alt)] text-[var(--app-text)] hover:border-[var(--app-border-strong)]"
                )
              ]}
            >
              <div class="flex items-center justify-between gap-3">
                <div>
                  <p class="font-mono text-[11px] uppercase tracking-[0.18em]">{draft.surface_id}</p>
                  <p class="mt-1 text-sm text-current/80">
                    {draft_title(draft)}
                  </p>
                </div>
                <span class="font-mono text-[11px] uppercase tracking-[0.18em]">
                  {draft.deployed_version || "undeployed"}
                </span>
              </div>
            </.link>
          </div>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Studio States</p>
          <div class="mt-4 grid gap-3">
            <.status_card label="Parse" value={stage_label(@source_analysis.parse_status)} tone={stage_tone(@source_analysis.parse_status)} />
            <.status_card label="Classification" value={editor_state_label(@source_analysis.classification)} tone={classification_tone(@source_analysis.classification)} />
            <.status_card label="Validation" value={stage_label(@source_analysis.validation_status)} tone={stage_tone(@source_analysis.validation_status)} />
            <.status_card label="Compile" value={stage_label(@source_analysis.compile_status)} tone={stage_tone(@source_analysis.compile_status)} />
          </div>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Deployment</p>
          <div class="mt-4 space-y-3 text-sm leading-6 text-[var(--app-text-muted)]">
            <p>
              <span class="font-semibold text-[var(--app-text)]">Panel:</span>
              {@deployment.panel_id}
            </p>
            <p>
              <span class="font-semibold text-[var(--app-text)]">Profile:</span>
              {@deployment.viewport_profile}
            </p>
            <p>
              <span class="font-semibold text-[var(--app-text)]">Compiled:</span>
              {@surface_draft.compiled_version || "none"}
            </p>
            <p>
              <span class="font-semibold text-[var(--app-text)]">Deployed:</span>
              {@surface_draft.deployed_version || "none"}
            </p>
            <p>
              <span class="font-semibold text-[var(--app-text)]">Assigned Surface:</span>
              {assignment_surface(@current_assignment)}
            </p>
            <p>
              <span class="font-semibold text-[var(--app-text)]">Assigned Version:</span>
              {assignment_version(@current_assignment)}
            </p>
          </div>

          <form phx-change="select_assignment_version" class="mt-4 space-y-2">
            <label class="space-y-1.5">
              <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                Assignment Version
              </span>
              <select name="assignment[version]" class={input_classes()}>
                <option
                  :for={version <- published_versions(@surface_draft)}
                  value={version}
                  selected={version == @selected_assignment_version}
                >
                  {version}
                </option>
              </select>
            </label>
            <p class="text-xs leading-5 text-[var(--app-text-dim)]">
              `Deploy` publishes versions. `Assign Panel` chooses which published version this panel opens at `/ops`.
            </p>
          </form>

          <div class="mt-4">
            <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
              Published Versions
            </p>
            <div class="mt-2 flex flex-wrap gap-2">
              <span
                :for={version <- published_versions(@surface_draft)}
                class={[
                  "border px-3 py-1 font-mono text-[11px] uppercase tracking-[0.18em]",
                  if(
                    version == @selected_assignment_version,
                    do:
                      "border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]",
                    else:
                      "border-[var(--app-border)] bg-[var(--app-surface-alt)] text-[var(--app-text-muted)]"
                  )
                ]}
              >
                {version}
              </span>
            </div>
          </div>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Bindings</p>
          <ul class="mt-4 space-y-2">
            <li :for={binding <- binding_list(@surface_definition)} class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2">
              <p class="font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text)]">{binding.name}</p>
              <p class="mt-1 text-sm text-[var(--app-text-muted)]">{inspect(binding.source)}</p>
            </li>
          </ul>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Diagnostics</p>
          <div class="mt-4 space-y-3">
            <div :if={@source_analysis.diagnostics == []} class="border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-4 py-4 text-sm text-[var(--app-good-text)]">
              No current diagnostics. This draft is ready for compile.
            </div>

            <div
              :for={diagnostic <- @source_analysis.diagnostics}
              class="border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-4 py-4 text-sm leading-6 text-[var(--app-danger-text)]"
            >
              {diagnostic}
            </div>
          </div>
        </section>
      </aside>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:tone, :string, required: true)

  def status_card(assigns) do
    ~H"""
    <div class={["border px-4 py-3", status_card_classes(@tone)]}>
      <p class="font-mono text-[11px] uppercase tracking-[0.22em]">{@label}</p>
      <p class="mt-1 text-sm font-semibold">{@value}</p>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  def surface_chip(assigns) do
    ~H"""
    <div class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2">
      <p class="font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">{@label}</p>
      <p class="mt-1 font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--app-text)]">{@value}</p>
    </div>
    """
  end

  defp load_surface(socket, surface_id) do
    default_surface_id = SurfaceDeployment.default_assignment().surface_id
    surface_id = surface_id || default_surface_id
    draft = SurfaceDraftStore.fetch(surface_id) || SurfaceDraftStore.fetch(default_surface_id)
    surface_id = draft.surface_id
    analysis = SurfaceCompiler.analyze(draft.source)
    current_assignment = SurfaceDeployment.default_assignment()

    deployment =
      SurfaceDeployment.fetch_surface_assignment(surface_id) ||
        current_assignment

    socket
    |> assign(:surface_id, surface_id)
    |> assign(:surface_title, surface_title(draft, analysis))
    |> assign(:deployment, deployment)
    |> assign(:current_assignment, current_assignment)
    |> assign(:surface_library, SurfaceDraftStore.list_drafts())
    |> assign(:persisted_source, draft.source)
    |> assign(:surface_draft, draft)
    |> assign(
      :selected_assignment_version,
      selected_assignment_version(draft, current_assignment)
    )
    |> assign(:studio_feedback, nil)
    |> assign_analysis(draft.source, analysis)
  end

  defp assign_analysis(socket, source, %Analysis{} = analysis) do
    definition = if analysis.classification == :visual, do: analysis.definition, else: nil
    runtime = if analysis.classification == :visual, do: analysis.runtime, else: nil
    screen = runtime && Surface.find_screen(runtime, runtime.default_screen)
    selected_profile = resolve_selected_profile(socket, runtime)
    variant = screen && selected_profile && Surface.select_variant(screen, selected_profile)

    socket
    |> assign(:draft_source, source)
    |> assign(:dirty?, source != socket.assigns.persisted_source)
    |> assign(:source_analysis, analysis)
    |> assign(
      :surface_title,
      (analysis.definition && analysis.definition.title) || socket.assigns.surface_title
    )
    |> assign(:surface_definition, definition)
    |> assign(:surface_runtime, runtime)
    |> assign(:surface_screen, screen)
    |> assign(:selected_profile, selected_profile)
    |> assign(:available_profiles, available_profiles(screen))
    |> assign(:surface_variant, variant)
    |> assign(:surface_context, preview_context(runtime))
  end

  defp surface_title(_draft, %Analysis{definition: %Surface{} = definition}), do: definition.title

  defp surface_title(draft, _analysis) do
    case draft.compiled_definition || draft.deployed_definition do
      %Surface{} = definition -> definition.title
      _ -> to_string(draft.surface_id)
    end
  end

  defp preview_context(%Surface.Runtime{} = runtime),
    do: Template.build_context(runtime, event_limit: 6)

  defp preview_context(_runtime), do: %{}

  defp available_profiles(nil), do: []

  defp available_profiles(screen) do
    screen.variants
    |> Map.keys()
    |> Enum.sort()
  end

  defp resolve_selected_profile(_socket, nil), do: nil

  defp resolve_selected_profile(socket, %Surface.Runtime{} = runtime) do
    deployment = socket.assigns[:deployment] || SurfaceDeployment.default_assignment()
    screen = Surface.find_screen(runtime, runtime.default_screen)
    available = available_profiles(screen)

    cond do
      socket.assigns[:selected_profile] in available ->
        socket.assigns.selected_profile

      deployment.viewport_profile in available ->
        deployment.viewport_profile

      available != [] ->
        hd(available)

      true ->
        nil
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

      updated_node = update_zone_node(template, zone, zone_params)

      {zone_id, %{zone | area: updated_area, node: updated_node}}
    end)
  end

  defp update_zone_node(_template, zone, params) do
    case zone.node do
      %Surface.Widget{} = widget ->
        type =
          params
          |> Map.get("type", widget.type)
          |> parse_atom(widget.type)

        binding =
          params
          |> Map.get("binding", widget.binding)
          |> parse_optional_atom(widget.binding)

        option_source =
          if type == widget.type do
            widget
          else
            %Surface.Widget{widget | options: %{}}
          end

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

  defp apply_visual_update(socket, %Surface{} = definition) do
    source = SurfacePrinter.print(definition, module: socket.assigns.surface_draft.source_module)
    analysis = SurfaceCompiler.analyze(source)

    if SurfaceCompiler.ready?(analysis) do
      socket
      |> assign(:studio_feedback, nil)
      |> assign_analysis(source, analysis)
    else
      assign(
        socket,
        :studio_feedback,
        feedback(
          :error,
          "Visual update rejected",
          hd(analysis.diagnostics) || "This change would leave the surface invalid."
        )
      )
    end
  end

  defp binding_list(nil), do: []
  defp binding_list(%Surface{bindings: bindings}), do: bindings

  defp draft_title(%{compiled_definition: %Surface{} = definition}), do: definition.title
  defp draft_title(%{deployed_definition: %Surface{} = definition}), do: definition.title
  defp draft_title(%{surface_id: surface_id}), do: to_string(surface_id)

  defp published_versions(draft), do: SurfaceDraftStore.published_versions(draft)

  defp assignment_summary(nil), do: "unassigned"

  defp assignment_summary(assignment) do
    "#{assignment.panel_id}:#{assignment.surface_id}"
  end

  defp assignment_surface(nil), do: "none"
  defp assignment_surface(assignment), do: assignment.surface_id

  defp assignment_version(nil), do: "none"
  defp assignment_version(assignment), do: assignment.surface_version || "none"

  defp selected_assignment_version(draft, assignment) do
    cond do
      assignment && assignment.surface_id == draft.surface_id && assignment.surface_version ->
        assignment.surface_version

      draft.deployed_version ->
        draft.deployed_version

      true ->
        published_versions(draft) |> List.first()
    end
  end

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

  defp feedback(tone, title, detail), do: %{tone: tone, title: title, detail: detail}

  defp params_surface_id(nil), do: nil
  defp params_surface_id(surface_id), do: surface_id

  defp mode_label(:dsl), do: "DSL"
  defp mode_label(:split), do: "Split"
  defp mode_label(:visual), do: "Visual"

  defp editor_state_label(:visual), do: "Visual"
  defp editor_state_label(:dsl_only), do: "DSL-only"
  defp editor_state_label(:invalid), do: "Invalid"

  defp stage_label(:ok), do: "OK"
  defp stage_label(:ready), do: "Ready"
  defp stage_label(:error), do: "Error"
  defp stage_label(:blocked), do: "Blocked"
  defp stage_label(:unknown), do: "Unknown"
  defp stage_label(other), do: inspect(other)

  defp classification_tone(:visual), do: "good"
  defp classification_tone(:dsl_only), do: "warn"
  defp classification_tone(:invalid), do: "danger"

  defp stage_tone(:ok), do: "good"
  defp stage_tone(:ready), do: "good"
  defp stage_tone(:error), do: "danger"
  defp stage_tone(:blocked), do: "warn"
  defp stage_tone(:unknown), do: "info"
  defp stage_tone(_other), do: "info"

  defp mode_button_classes(true) do
    "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-info-text)]"
  end

  defp mode_button_classes(false) do
    "border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-muted)] transition hover:border-[var(--app-border-strong)] hover:text-[var(--app-text)]"
  end

  defp profile_button_classes(true) do
    "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-3 py-1.5 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-info-text)]"
  end

  defp profile_button_classes(false) do
    "border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1.5 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-muted)] transition hover:border-[var(--app-border-strong)] hover:text-[var(--app-text)]"
  end

  defp action_button_classes(:good) do
    "border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-4 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-good-text)]"
  end

  defp action_button_classes(:warn) do
    "border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-4 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-warn-text)]"
  end

  defp action_button_classes(:info) do
    "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-4 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-info-text)]"
  end

  defp action_button_classes(:neutral) do
    "border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text)]"
  end

  defp feedback_classes(:ok), do: "border-[var(--app-good-border)] bg-[var(--app-good-surface)]"

  defp feedback_classes(:error),
    do: "border-[var(--app-danger-border)] bg-[var(--app-danger-surface)]"

  defp status_card_classes("good"),
    do: "border-[var(--app-good-border)] bg-[var(--app-good-surface)] text-[var(--app-good-text)]"

  defp status_card_classes("warn"),
    do: "border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] text-[var(--app-warn-text)]"

  defp status_card_classes("danger"),
    do:
      "border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"

  defp status_card_classes(_tone),
    do: "border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]"

  defp editor_grid_classes(:visual), do: "grid gap-4"

  defp editor_grid_classes(:split),
    do: "grid gap-4 2xl:grid-cols-[minmax(0,1.15fr)_minmax(0,0.85fr)]"

  defp input_classes do
    "w-full border border-[var(--app-border)] bg-[var(--app-shell)] px-3 py-2 text-sm text-[var(--app-text)] outline-none transition focus:border-[var(--app-info-border)]"
  end

  defp mini_input_classes do
    "w-20 border border-[var(--app-border)] bg-[var(--app-shell)] px-2 py-1.5 text-sm text-[var(--app-text)] outline-none transition focus:border-[var(--app-info-border)]"
  end

  defp mini_text_input_classes do
    "w-36 border border-[var(--app-border)] bg-[var(--app-shell)] px-2 py-1.5 text-sm text-[var(--app-text)] outline-none transition focus:border-[var(--app-info-border)]"
  end

  defp select_classes do
    "border border-[var(--app-border)] bg-[var(--app-shell)] px-2 py-1.5 text-sm text-[var(--app-text)] outline-none transition focus:border-[var(--app-info-border)]"
  end

  defp textarea_classes do
    "w-full border border-[var(--app-border)] bg-[var(--app-shell)] px-3 py-2 text-sm leading-6 text-[var(--app-text)] outline-none transition focus:border-[var(--app-info-border)]"
  end

  defp dsl_textarea_classes do
    "min-h-[42rem] w-full border border-[var(--app-border)] bg-[var(--app-shell)] px-4 py-3 font-mono text-[13px] leading-6 text-[var(--app-text)] outline-none transition focus:border-[var(--app-info-border)]"
  end
end
