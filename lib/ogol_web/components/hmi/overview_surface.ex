defmodule OgolWeb.HMI.OverviewSurface do
  use OgolWeb, :html

  alias Ogol.HMI.Surface.{Group, Variant, Widget, Zone}
  alias OgolWeb.Components.StatusBadge

  attr(:surface, :map, required: true)
  attr(:screen, :map, required: true)
  attr(:variant, :map, required: true)
  attr(:context, :map, required: true)
  attr(:operator_feedback, :any, default: nil)

  def render(assigns) do
    assigns = assign(assigns, :screen_tabs, screen_tabs(assigns.surface, assigns.screen))

    ~H"""
    <section class="flex h-full min-h-0 flex-col gap-4">
      <nav
        :if={length(@screen_tabs) > 1}
        data-test="surface-screen-tabs"
        class="app-panel flex flex-wrap items-center gap-2 px-3 py-3"
      >
        <.link
          :for={tab <- @screen_tabs}
          navigate={tab.path}
          data-test={"surface-screen-tab-#{tab.id}"}
          aria-current={if(tab.active?, do: "page", else: nil)}
          class={[
            "inline-flex border px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] transition",
            if(tab.active?,
              do:
                "border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]",
              else:
                "border-[var(--app-border)] bg-[var(--app-surface-alt)] text-[var(--app-text-muted)] hover:border-[var(--app-border-strong)] hover:bg-[var(--app-surface-strong)] hover:text-[var(--app-text)]"
            )
          ]}
        >
          {tab.label}
        </.link>
      </nav>

      <section
        data-test={"surface-screen-#{@screen.id}"}
        data-profile={@variant.profile_id}
        class={["grid h-full min-h-0 flex-1 overflow-hidden", gap_class(@variant.grid.gap)]}
        style={grid_style(@variant)}
      >
        <div
          :for={zone <- ordered_zones(@variant)}
          class="min-h-0 overflow-hidden"
          data-zone={zone.id}
          style={zone_style(zone)}
        >
          <.zone_node
            node={zone.node}
            context={@context}
            operator_feedback={@operator_feedback}
          />
        </div>
      </section>
    </section>
    """
  end

  attr(:node, :any, required: true)
  attr(:context, :map, required: true)
  attr(:operator_feedback, :any, default: nil)

  def zone_node(%{node: %Widget{type: :summary_strip}} = assigns) do
    assigns = assign(assigns, :summary, binding_data(assigns.context, assigns.node.binding, %{}))

    ~H"""
    <.summary_strip summary={@summary} />
    """
  end

  def zone_node(%{node: %Widget{type: :alarm_strip}} = assigns) do
    assigns =
      assign(assigns, :alarm_summary, binding_data(assigns.context, assigns.node.binding, %{}))

    ~H"""
    <.alarm_strip alarm_summary={@alarm_summary} />
    """
  end

  def zone_node(%{node: %Widget{type: :procedure_panel}} = assigns) do
    orchestration_status =
      default_procedure_status()
      |> Map.merge(binding_data(assigns.context, assigns.node.binding, %{}))

    catalog = Map.get(assigns.context, :procedure_catalog, [])

    assigns =
      assigns
      |> assign(:orchestration_status, orchestration_status)
      |> assign(:procedure_catalog, catalog)
      |> assign(:selected_entry, Enum.find(catalog, & &1.selected?))
      |> assign(:active_entry, Enum.find(catalog, & &1.active?))

    ~H"""
    <section data-test="procedure-panel" class="app-panel h-full min-h-0 overflow-hidden">
      <div class="border-b border-[var(--app-border)] px-5 py-4">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <p class="app-kicker">Primary Action Area</p>
            <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Procedure control</h2>
          </div>

          <div class="flex flex-wrap gap-2">
            <span class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
              {procedure_control_mode(@orchestration_status.control_mode)}
            </span>
            <span class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
              {procedure_owner_label(@orchestration_status.owner_kind)}
            </span>
          </div>
        </div>
      </div>

      <div class="h-[calc(100%-5.5rem)] overflow-y-auto p-4">
        <div
          :if={@operator_feedback}
          class={["mb-4 border px-4 py-3", operator_feedback_classes(@operator_feedback.status)]}
        >
          <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
            <div>
              <p class="app-kicker">Operator Action</p>
              <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">
                {operator_feedback_summary(@operator_feedback)}
              </p>
            </div>

            <p class="font-mono text-[11px] text-[var(--app-text-muted)] sm:max-w-[28rem] sm:text-right">
              {operator_feedback_detail(@operator_feedback)}
            </p>
          </div>
        </div>

        <div class="grid gap-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(0,1.05fr)]">
          <div class="space-y-4">
            <div class="grid gap-2 sm:grid-cols-2">
              <.mini_kv label="Owner" value={procedure_owner_label(@orchestration_status.owner_kind)} />
              <.mini_kv label="Trust" value={procedure_trust_label(@orchestration_status.runtime_trust_state)} />
              <.mini_kv label="Runtime" value={procedure_runtime_label(@orchestration_status.runtime_observed)} />
              <.mini_kv label="Run Policy" value={procedure_run_policy(@orchestration_status.run_policy)} />
              <.mini_kv label="Selected" value={selected_label(@selected_entry)} />
            </div>

            <div
              :if={@orchestration_status.runtime_blockers != []}
              class="border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-4 py-3"
            >
              <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-danger-text)]">
                Runtime blockers
              </p>
              <div class="mt-2 space-y-1 text-sm leading-6 text-[var(--app-danger-text)]">
                <p :for={blocker <- @orchestration_status.runtime_blockers}>{blocker}</p>
              </div>
            </div>

            <div
              :if={@orchestration_status.scope_matches_runtime? == false and @orchestration_status.topology_scope != :all}
              class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-3 text-sm leading-6 text-[var(--app-text-muted)]"
            >
              This surface is scoped to {@orchestration_status.topology_scope}, but that topology is not active in the runtime.
            </div>

            <div
              :if={not is_nil(@active_entry) and not is_nil(@orchestration_status.active_run)}
              class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
            >
              <div class="flex flex-wrap items-center justify-between gap-3">
                <div>
                  <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                    Active procedure
                  </p>
                  <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">
                    {@active_entry.label}
                  </h3>
                  <p :if={@active_entry.summary} class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">
                    {@active_entry.summary}
                  </p>
                </div>

                <span class="border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
                  {format_value(@orchestration_status.active_run.status)}
                </span>
              </div>

              <div class="mt-3 grid gap-2 sm:grid-cols-2">
                <.mini_kv label="Procedure" value={format_value(@orchestration_status.active_run.current_procedure || :root)} />
                <.mini_kv label="Step" value={format_value(@orchestration_status.active_run.current_step_label || :waiting)} />
              </div>

              <div class="mt-4 flex flex-wrap gap-2">
                <.procedure_button
                  :if={@orchestration_status.actions.pause?}
                  data_test="procedure-pause"
                  action="pause"
                  label="Pause"
                  enabled={true}
                />
                <.procedure_button
                  :if={@orchestration_status.actions.resume?}
                  data_test="procedure-resume"
                  action="resume"
                  label="Resume"
                  enabled={true}
                />
                <.procedure_button
                  :if={@orchestration_status.actions.acknowledge? and @orchestration_status.active_run.status == :held}
                  data_test="procedure-acknowledge-held"
                  action="acknowledge"
                  label="Acknowledge"
                  enabled={true}
                />
                <.procedure_button
                  :if={@orchestration_status.actions.abort?}
                  data_test="procedure-abort"
                  action="abort"
                  label="Abort"
                  enabled={true}
                />
                <.procedure_button
                  :if={@orchestration_status.actions.request_manual_takeover?}
                  data_test="procedure-request-manual-takeover"
                  action="request_manual_takeover"
                  label="Request Manual"
                  enabled={true}
                />
              </div>
            </div>

            <div
              :if={is_nil(@active_entry) and not is_nil(@orchestration_status.terminal_result)}
              class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
            >
              <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                Last result
              </p>
              <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">
                {format_value(@orchestration_status.terminal_result.status)}
              </h3>
              <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                {terminal_result_summary(@orchestration_status.terminal_result)}
              </p>

              <div class="mt-4 flex flex-wrap gap-2">
                <.procedure_button
                  data_test={terminal_result_button_test(@orchestration_status)}
                  action={terminal_result_action(@orchestration_status)}
                  label={terminal_result_label(@orchestration_status)}
                  enabled={terminal_result_enabled?(@orchestration_status)}
                />
              </div>
            </div>

            <div :if={is_nil(@active_entry) and is_nil(@orchestration_status.terminal_result)} class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
              <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                Cell mode
              </p>
              <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">
                {procedure_control_mode(@orchestration_status.control_mode)}
              </h3>
              <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                {idle_panel_summary(@orchestration_status, @selected_entry)}
              </p>

              <div class="mt-4 flex flex-wrap gap-2">
                <.procedure_button
                  data_test="procedure-arm-auto"
                  action="arm_auto"
                  label="Arm Auto"
                  enabled={@orchestration_status.actions.arm_auto?}
                />
                <.procedure_button
                  data_test="procedure-switch-to-manual"
                  action="switch_to_manual"
                  label="Manual"
                  enabled={@orchestration_status.actions.switch_to_manual?}
                />
                <.procedure_button
                  :if={@orchestration_status.actions.set_cycle_policy?}
                  data_test="procedure-set-cycle-policy"
                  action="set_cycle_policy"
                  label="Cycle"
                  enabled={true}
                />
                <.procedure_button
                  :if={@orchestration_status.actions.set_once_policy?}
                  data_test="procedure-set-once-policy"
                  action="set_once_policy"
                  label="Once"
                  enabled={true}
                />
                <.procedure_button
                  data_test="procedure-run-selected"
                  action="run_selected"
                  label="Run Selected"
                  enabled={@orchestration_status.actions.run_selected?}
                />
              </div>
            </div>
          </div>

          <div class="space-y-3">
            <div class="flex items-center justify-between">
              <div>
                <p class="app-kicker">Procedure Catalog</p>
                <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">Runnable procedures</h3>
              </div>
              <span class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
                {length(@procedure_catalog)} visible
              </span>
            </div>

            <div :if={@procedure_catalog == []} class="app-panel-muted px-4 py-6 text-sm leading-6 text-[var(--app-text-muted)]">
              No procedures are available for this surface scope.
            </div>

            <article
              :for={entry <- @procedure_catalog}
              class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
              data-test={"procedure-entry-#{entry.sequence_id}"}
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h4 class="text-base font-semibold text-[var(--app-text)]">{entry.label}</h4>
                    <span :if={entry.selected?} class="border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-info-text)]">
                      selected
                    </span>
                    <span :if={entry.active?} class="border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-good-text)]">
                      active
                    </span>
                    <span
                      :if={entry.startable? and not entry.active?}
                      class="border border-[var(--app-border)] bg-[var(--app-surface)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-muted)]"
                    >
                      startable
                    </span>
                  </div>

                  <p :if={entry.summary} class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">
                    {entry.summary}
                  </p>

                  <p
                    :if={procedure_entry_reason(entry)}
                    class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]"
                  >
                    {procedure_entry_reason(entry)}
                  </p>
                </div>

                <div class="flex flex-wrap gap-2">
                  <button
                    type="button"
                    phx-click="procedure_control"
                    phx-value-action="select"
                    phx-value-sequence_id={entry.sequence_id}
                    disabled={!procedure_selectable?(entry, @orchestration_status)}
                    data-test={"procedure-select-#{entry.sequence_id}"}
                    class={control_button_classes(procedure_selectable?(entry, @orchestration_status))}
                  >
                    {if entry.selected?, do: "Selected", else: "Select"}
                  </button>
                </div>
              </div>
            </article>
          </div>
        </div>
      </div>
    </section>
    """
  end

  def zone_node(%{node: %Widget{type: :status_tile} = node} = assigns) do
    data = binding_data(assigns.context, node.binding, %{})

    assigns =
      assigns
      |> assign(:status_label, status_tile_label(node, data))
      |> assign(:status_value, status_tile_value(node, data))
      |> assign(:status_detail, status_tile_detail(node, data))

    ~H"""
    <section class="app-panel flex h-full min-h-0 flex-col justify-between overflow-hidden px-4 py-4">
      <div>
        <p class="app-kicker">{@status_label}</p>
        <p class="mt-3 text-3xl font-semibold text-[var(--app-text)]">{@status_value}</p>
      </div>
      <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">{@status_detail}</p>
    </section>
    """
  end

  def zone_node(%{node: %Widget{type: :value_grid} = node} = assigns) do
    data = binding_data(assigns.context, node.binding, %{})
    assigns = assign(assigns, :entries, value_grid_entries(node, data))

    ~H"""
    <section class="app-panel h-full min-h-0 overflow-hidden">
      <div class="border-b border-[var(--app-border)] px-4 py-4">
        <p class="app-kicker">Value Grid</p>
        <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">Projected values</h3>
      </div>

      <div class="grid gap-3 p-4 sm:grid-cols-2">
        <div :for={{label, value} <- @entries} class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-3">
          <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">{label}</p>
          <p class="mt-2 text-lg font-semibold text-[var(--app-text)]">{value}</p>
        </div>
      </div>
    </section>
    """
  end

  def zone_node(%{node: %Widget{type: :fault_list} = node} = assigns) do
    data = binding_data(assigns.context, node.binding, %{})
    assigns = assign(assigns, :items, fault_list_items(node, data))

    ~H"""
    <section class="app-panel h-full min-h-0 overflow-hidden">
      <div class="border-b border-[var(--app-border)] px-4 py-4">
        <p class="app-kicker">Fault List</p>
        <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">Visible issues</h3>
      </div>

      <div class="space-y-2 p-4">
        <div :if={@items == []} class="app-panel-muted px-4 py-5 text-sm leading-6 text-[var(--app-text-muted)]">
          No visible issues in the current binding projection.
        </div>

        <div
          :for={item <- @items}
          class="border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-3 py-2.5 text-sm text-[var(--app-danger-text)]"
        >
          {item}
        </div>
      </div>
    </section>
    """
  end

  def zone_node(%{node: %Widget{type: :attention_lane}} = assigns) do
    assigns = assign(assigns, :lane, binding_data(assigns.context, assigns.node.binding, %{}))

    ~H"""
    <section class="h-full min-h-0 space-y-4">
      <div
        :if={@operator_feedback}
        class={["border px-4 py-3", operator_feedback_classes(@operator_feedback.status)]}
      >
        <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <p class="app-kicker">Operator Action</p>
            <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">
              {operator_feedback_summary(@operator_feedback)}
            </p>
          </div>

          <p class="font-mono text-[11px] text-[var(--app-text-muted)] sm:max-w-[28rem] sm:text-right">
            {operator_feedback_detail(@operator_feedback)}
          </p>
        </div>
      </div>

      <.attention_lane lane={@lane} />
    </section>
    """
  end

  def zone_node(%{node: %Widget{type: :machine_grid}} = assigns) do
    assigns = assign(assigns, :registry, binding_data(assigns.context, assigns.node.binding, %{}))

    ~H"""
    <.machine_grid registry={@registry} />
    """
  end

  def zone_node(%{node: %Widget{type: :machine_summary_card} = node} = assigns) do
    registry = binding_data(assigns.context, node.binding, %{})
    assigns = assign(assigns, :machine, machine_summary_item(node, registry))

    ~H"""
    <section class="app-panel h-full min-h-0 overflow-hidden">
      <div class="border-b border-[var(--app-border)] px-4 py-4">
        <p class="app-kicker">Machine Summary</p>
        <h3 class="mt-1 text-lg font-semibold text-[var(--app-text)]">Focused unit</h3>
      </div>

      <div :if={@machine} class="p-4">
        <div class="flex items-center justify-between gap-3">
          <.link
            navigate={~p"/ops/machines/#{@machine.machine_id}"}
            class="text-lg font-semibold text-[var(--app-text)] underline decoration-[var(--app-border-strong)] underline-offset-4"
          >
            {@machine.machine_id}
          </.link>
          <StatusBadge.badge status={@machine.health} />
        </div>

        <div class="mt-4 grid gap-2 sm:grid-cols-3">
          <.mini_kv
            label="State"
            value={
              format_value(
                Map.get(@machine.public_status || %{}, :current_state) ||
                  @machine.current_state || :unknown
              )
            }
          />
          <.mini_kv label="Signal" value={format_value(@machine.last_signal || :none)} />
          <.mini_kv label="Linked" value={if(@machine.connected?, do: "yes", else: "no")} />
        </div>
      </div>

      <div :if={is_nil(@machine)} class="p-4">
        <div class="app-panel-muted px-4 py-5 text-sm leading-6 text-[var(--app-text-muted)]">
          No machine summary is available for the selected binding.
        </div>
      </div>
    </section>
    """
  end

  def zone_node(%{node: %Widget{type: :skill_button_group} = node} = assigns) do
    data = binding_data(assigns.context, node.binding, %{})

    assigns =
      assigns
      |> assign(:machine_id, skill_button_machine_id(data))
      |> assign(:connected?, Map.get(data, :connected?, false))
      |> assign(:skills, skill_button_skills(node, data))

    ~H"""
    <section class="app-panel h-full min-h-0 overflow-hidden">
      <div class="border-b border-[var(--app-border)] px-5 py-4">
        <p class="app-kicker">Primary Action Area</p>
        <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Safe operator actions</h2>
      </div>

      <div class="grid gap-3 p-4">
        <div :if={@machine_id} class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-3">
          <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
            Target
          </p>
          <p class="mt-2 text-base font-semibold text-[var(--app-text)]">{@machine_id}</p>
        </div>

        <div :if={@skills == []} class="app-panel-muted px-4 py-5 text-sm leading-6 text-[var(--app-text-muted)]">
          No safe operator skills are currently available for this surface binding.
        </div>

        <div :if={@skills != []} class="flex flex-wrap gap-2">
          <button
            :for={skill <- @skills}
            type="button"
            phx-click="dispatch_control"
            phx-value-machine_id={@machine_id}
            phx-value-name={to_string(skill.name)}
            disabled={!@connected? or skill.available? == false or is_nil(@machine_id)}
            data-test={"control-#{@machine_id}-skill-#{skill.name}"}
            class={control_button_classes(@connected? and skill.available? != false and not is_nil(@machine_id))}
            title={skill.summary || format_skill_name(skill.name)}
          >
            {format_skill_name(skill.name)}
          </button>
        </div>
      </div>
    </section>
    """
  end

  def zone_node(%{node: %Widget{type: :event_ticker}} = assigns) do
    assigns =
      assign(assigns, :event_stream, binding_data(assigns.context, assigns.node.binding, %{}))

    ~H"""
    <.event_ticker event_stream={@event_stream} />
    """
  end

  def zone_node(%{node: %Widget{type: :quick_links}} = assigns) do
    assigns = assign(assigns, :links, binding_data(assigns.context, assigns.node.binding, []))

    ~H"""
    <.quick_links links={@links} />
    """
  end

  def zone_node(%{node: %Group{} = group} = assigns) do
    assigns = assign(assigns, :group, group)

    ~H"""
    <section class={["h-full min-h-0", group_container_classes(@group.mode)]}>
      <div
        :for={child <- @group.children}
        class={group_child_classes(@group.mode)}
      >
        <.zone_node node={child} context={@context} operator_feedback={@operator_feedback} />
      </div>
    </section>
    """
  end

  def zone_node(assigns) do
    assigns =
      assigns
      |> assign(:node_type, inspect(assigns.node))

    ~H"""
    <section class="app-panel flex h-full min-h-0 items-center justify-center px-5 py-6">
      <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
        unsupported node {@node_type}
      </p>
    </section>
    """
  end

  attr(:summary, :map, required: true)

  def summary_strip(assigns) do
    ~H"""
    <section class="app-panel h-full overflow-hidden">
      <div class="border-b border-[var(--app-border)] px-5 py-4">
        <p class="app-kicker">Status Rail</p>
        <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Runtime posture at a glance</h2>
      </div>

      <div class="grid h-[calc(100%-5.5rem)] gap-px bg-[var(--app-border)] sm:grid-cols-2 xl:grid-cols-4">
        <.summary_cell label="Machines" value={summary_count(@summary, :total)} detail="registered units" />
        <.summary_cell label="Healthy" value={summary_count(@summary, :active)} detail="healthy, waiting, or running" tone={:good} />
        <.summary_cell label="Faulted" value={summary_count(@summary, :faulted)} detail="faulted or crashed" tone={:danger} />
        <.summary_cell label="Offline" value={summary_count(@summary, :offline)} detail="stopped or disconnected" />
        <.summary_cell label="Linked" value={summary_linked(@summary)} detail="runtime links" tone={:info} />
        <.summary_cell label="Observed" value={summary_count(@summary, :observed_machines)} detail="dependency channels" />
        <.summary_cell label="Alarms" value={summary_count(@summary, :alarms)} detail="active projected alarms" tone={:warn} />
        <.summary_cell label="Transition" value={format_age(summary_timestamp(@summary))} detail={format_timestamp(summary_timestamp(@summary))} />
      </div>
    </section>
    """
  end

  attr(:alarm_summary, :map, required: true)

  def alarm_strip(assigns) do
    ~H"""
    <section class="app-panel h-full overflow-hidden">
      <div class="border-b border-[var(--app-border)] px-5 py-4">
        <div class="flex flex-wrap items-center gap-3">
          <p class="app-kicker">Critical Visibility</p>
          <StatusBadge.badge status={alarm_strip_status(@alarm_summary)} />
        </div>
        <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Active alarms and fault posture</h2>
      </div>

      <div class="grid gap-4 px-5 py-4 sm:grid-cols-[minmax(0,1fr)_14rem]">
        <div class="space-y-2">
          <p class="text-sm leading-6 text-[var(--app-text-muted)]">
            {alarm_count(@alarm_summary, :faults)} fault event(s), {alarm_count(@alarm_summary, :alarms)} alarm(s), and {alarm_count(@alarm_summary, :offline_machines)} offline machine(s) are currently projected into runtime visibility.
          </p>
          <div class="flex flex-wrap gap-2">
            <span
              :for={machine_id <- alarm_affected(@alarm_summary)}
              class="border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-2.5 py-1 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-danger-text)]"
            >
              {machine_id}
            </span>
            <span
              :if={alarm_affected(@alarm_summary) == []}
              class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-2.5 py-1 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-muted)]"
            >
              no affected units
            </span>
          </div>
        </div>

        <div class="grid gap-2 sm:grid-cols-2 sm:content-start">
          <.mini_kv label="Faults" value={to_string(alarm_count(@alarm_summary, :faults))} />
          <.mini_kv label="Alarms" value={to_string(alarm_count(@alarm_summary, :alarms))} />
          <.mini_kv label="Faulted" value={to_string(alarm_count(@alarm_summary, :faulted_machines))} />
          <.mini_kv label="Offline" value={to_string(alarm_count(@alarm_summary, :offline_machines))} />
        </div>
      </div>
    </section>
    """
  end

  attr(:lane, :map, required: true)

  def attention_lane(assigns) do
    ~H"""
    <section class="app-panel h-full overflow-hidden">
      <div class="flex items-center justify-between border-b border-[var(--app-border)] px-5 py-4">
        <div>
          <p class="app-kicker">Primary Action Area</p>
          <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Needs immediate attention</h2>
        </div>
        <span class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
          {length(lane_machines(@lane))} visible
        </span>
      </div>

      <div class="space-y-3 p-4">
        <div :if={lane_machines(@lane) == []} class="app-panel-muted px-5 py-6">
          <h3 class="text-base font-semibold text-[var(--app-text)]">No immediate runtime issues</h3>
          <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            No machines are currently faulted, crashed, or offline.
          </p>
        </div>

        <.attention_row :for={machine <- lane_machines(@lane)} machine={machine} />

        <p
          :if={lane_overflow(@lane) > 0}
          class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-muted)]"
        >
          +{lane_overflow(@lane)} more units require review on a drill-down surface
        </p>
      </div>
    </section>
    """
  end

  attr(:registry, :map, required: true)

  def machine_grid(assigns) do
    ~H"""
    <section class="app-panel h-full min-h-0 overflow-hidden">
      <div class="flex items-center justify-between border-b border-[var(--app-border)] px-5 py-4">
        <div>
          <p class="app-kicker">Machine Tiles</p>
          <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Safe runtime controls</h2>
        </div>
        <span class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
          {length(registry_machines(@registry))} visible
        </span>
      </div>

      <div class="grid gap-3 p-4 xl:grid-cols-2">
        <div :if={registry_machines(@registry) == []} class="app-panel-muted px-5 py-6 xl:col-span-2">
          <h3 class="text-base font-semibold text-[var(--app-text)]">No runtime machines linked</h3>
          <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            Start a machine or topology and the assigned surface will populate automatically.
          </p>
        </div>

        <.runtime_machine_tile :for={machine <- registry_machines(@registry)} machine={machine} />
      </div>

      <div
        :if={registry_overflow(@registry) > 0}
        class="border-t border-[var(--app-border)] px-4 py-3 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-muted)]"
      >
        +{registry_overflow(@registry)} more units hidden to preserve fixed-surface density
      </div>
    </section>
    """
  end

  attr(:links, :list, required: true)

  def quick_links(assigns) do
    ~H"""
    <section class="app-panel h-full overflow-hidden">
      <div class="border-b border-[var(--app-border)] px-5 py-4">
        <p class="app-kicker">Navigation Dock</p>
        <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Deterministic next actions</h2>
      </div>

      <div class="grid gap-3 p-4">
        <.quick_link
          :for={link <- @links}
          label={link.label}
          detail={link.detail}
          path={link.path}
          disabled={link.disabled}
        />
      </div>
    </section>
    """
  end

  attr(:event_stream, :map, required: true)

  def event_ticker(assigns) do
    ~H"""
    <section class="app-panel h-full min-h-0 overflow-hidden">
      <div class="flex items-center justify-between border-b border-[var(--app-border)] px-5 py-4">
        <div>
          <p class="app-kicker">Detail Pane</p>
          <h2 class="mt-1 text-xl font-semibold text-[var(--app-text)]">Recent runtime notifications</h2>
        </div>
        <span class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-muted)]">
          {length(event_stream_events(@event_stream))} latest
        </span>
      </div>

      <div class="space-y-2 p-4">
        <div :if={event_stream_events(@event_stream) == []} class="app-panel-muted px-4 py-6 text-sm text-[var(--app-text-muted)]">
          No runtime notifications yet.
        </div>

        <.activity_entry :for={event <- event_stream_events(@event_stream)} event={event} />
      </div>

      <div
        :if={event_stream_overflow(@event_stream) > 0}
        class="border-t border-[var(--app-border)] px-4 py-3 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-muted)]"
      >
        +{event_stream_overflow(@event_stream)} older notifications omitted from this surface
      </div>
    </section>
    """
  end

  attr(:machine, :map, required: true)

  def runtime_machine_tile(assigns) do
    assigns =
      assigns
      |> assign(:machine_id, to_string(assigns.machine.machine_id))
      |> assign(:skills, Enum.take(assigns.machine.skills || [], 4))

    ~H"""
    <article class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <.link
              navigate={~p"/ops/machines/#{@machine_id}"}
              class="text-lg font-semibold text-[var(--app-text)] underline decoration-[var(--app-border-strong)] underline-offset-4"
            >
              {@machine_id}
            </.link>
            <StatusBadge.badge status={@machine.health} />
          </div>
          <p class="mt-1 font-mono text-[11px] text-[var(--app-text-dim)]">{format_module(@machine.module)}</p>
        </div>

        <span class={link_classes(@machine.connected?)}>
          {if @machine.connected?, do: "linked", else: "offline"}
        </span>
      </div>

      <div class="mt-3 grid gap-2 sm:grid-cols-3">
        <.mini_kv
          label="State"
          value={
            format_value(
              Map.get(@machine.public_status || %{}, :current_state) ||
                @machine.current_state || :unknown
            )
          }
        />
        <.mini_kv label="Signal" value={format_value(@machine.last_signal || :none)} />
        <.mini_kv label="Restarts" value={to_string(@machine.restart_count)} />
      </div>

      <div class="mt-3 border-t border-[var(--app-border)] pt-3">
        <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Controls</p>
        <div class="mt-2 flex flex-wrap gap-2">
          <button
            :for={skill <- @skills}
            type="button"
            phx-click="dispatch_control"
            phx-value-machine_id={@machine_id}
            phx-value-name={to_string(skill.name)}
            disabled={!@machine.connected? or skill.available? == false}
            data-test={"control-#{@machine_id}-skill-#{skill.name}"}
            class={control_button_classes(@machine.connected? and skill.available? != false)}
            title={skill.summary || format_skill_name(skill.name)}
          >
            {format_skill_name(skill.name)}
          </button>
        </div>
      </div>
    </article>
    """
  end

  attr(:machine, :map, required: true)

  def attention_row(assigns) do
    ~H"""
    <article class="app-panel-muted px-4 py-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-3">
            <.link navigate={~p"/ops/machines/#{@machine.machine_id}"} class="text-lg font-semibold text-[var(--app-text)] underline decoration-[var(--app-border-strong)] underline-offset-4">
              {@machine.machine_id}
            </.link>
            <StatusBadge.badge status={@machine.health} />
          </div>
          <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            {attention_summary(@machine)}
          </p>
        </div>

        <div class="grid gap-2 sm:grid-cols-3">
          <.mini_kv label="State" value={format_value(@machine.current_state || :unknown)} />
          <.mini_kv label="Signal" value={format_value(@machine.last_signal || :none)} />
          <.mini_kv label="Restarts" value={to_string(@machine.restart_count)} />
        </div>
      </div>
    </article>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)
  attr(:tone, :atom, default: :neutral)

  def summary_cell(assigns) do
    ~H"""
    <div class={["px-4 py-4", summary_cell_classes(@tone)]}>
      <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-[var(--app-text-dim)]">{@label}</p>
      <p class="mt-2 text-2xl font-semibold text-[var(--app-text)]">{@value}</p>
      <p class="mt-2 text-[12px] leading-5 text-[var(--app-text-muted)]">{@detail}</p>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  def mini_kv(assigns) do
    ~H"""
    <div class="border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-2.5">
      <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">{@label}</p>
      <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">{@value}</p>
    </div>
    """
  end

  attr(:data_test, :string, required: true)
  attr(:action, :string, required: true)
  attr(:label, :string, required: true)
  attr(:enabled, :boolean, default: false)

  def procedure_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="procedure_control"
      phx-value-action={@action}
      disabled={!@enabled}
      data-test={@data_test}
      class={control_button_classes(@enabled)}
    >
      {@label}
    </button>
    """
  end

  attr(:label, :string, required: true)
  attr(:detail, :string, required: true)
  attr(:path, :string, required: true)
  attr(:disabled, :boolean, default: false)

  def quick_link(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class={[
        "block border px-4 py-4 transition",
        if(@disabled,
          do: "pointer-events-none border-[var(--app-border)] bg-[var(--app-surface-alt)] text-[var(--app-text-dim)]",
          else:
            "border-[var(--app-border)] bg-[var(--app-surface-alt)] hover:border-[var(--app-border-strong)] hover:bg-[var(--app-surface-strong)]"
        )
      ]}
    >
      <p class="font-mono text-[11px] uppercase tracking-[0.22em]">{@label}</p>
      <p class="mt-2 text-sm leading-6">{@detail}</p>
    </.link>
    """
  end

  attr(:event, :map, required: true)

  def activity_entry(assigns) do
    ~H"""
    <article class="app-panel-muted px-3 py-3">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <p class="truncate text-sm font-semibold text-[var(--app-text)]">{format_event_type(@event.type)}</p>
            <span class="border border-[var(--app-border)] bg-[var(--app-surface)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-muted)]">
              {event_target(@event)}
            </span>
          </div>
          <p class="mt-1 truncate font-mono text-[11px] text-[var(--app-text-dim)]">{event_scope(@event)}</p>
          <div class="mt-2 flex flex-wrap gap-1.5">
            <span
              :for={tag <- event_tags(@event)}
              class="border border-[var(--app-border)] bg-[var(--app-surface)] px-2 py-0.5 font-mono text-[10px] text-[var(--app-text-muted)]"
            >
              {tag}
            </span>
          </div>
        </div>

        <div class="shrink-0 text-right">
          <p class="font-mono text-[11px] text-[var(--app-text-dim)]">{format_timestamp(@event.occurred_at)}</p>
          <p class="mt-1 font-mono text-[10px] text-[var(--app-text-dim)]">{format_age(@event.occurred_at)}</p>
        </div>
      </div>
    </article>
    """
  end

  defp binding_data(_context, nil, fallback), do: fallback
  defp binding_data(context, binding, fallback), do: Map.get(context, binding, fallback)

  defp screen_tabs(
         %{id: surface_id, screens: screens, default_screen: default_screen},
         current_screen
       )
       when is_map(screens) do
    screens
    |> Map.values()
    |> Enum.sort_by(fn screen ->
      {if(screen.id == default_screen, do: 0, else: 1), screen.title || to_string(screen.id)}
    end)
    |> Enum.map(fn screen ->
      %{
        id: screen.id,
        label: screen.title || humanize_key(screen.id),
        path: "/ops/hmis/#{surface_id}/#{screen.id}",
        active?: to_string(screen.id) == to_string(current_screen.id)
      }
    end)
  end

  defp ordered_zones(%Variant{zones: zones}) do
    zones
    |> Map.values()
    |> Enum.sort_by(fn zone -> {zone.area.row, zone.area.col, zone.id} end)
  end

  defp grid_style(%Variant{grid: grid}) do
    "grid-template-columns: repeat(#{grid.columns}, minmax(0, 1fr));" <>
      "grid-template-rows: repeat(#{grid.rows}, minmax(0, 1fr));"
  end

  defp zone_style(%Zone{area: area}) do
    "grid-column: #{area.col} / span #{area.col_span};" <>
      "grid-row: #{area.row} / span #{area.row_span};"
  end

  defp gap_class(:sm), do: "gap-2"
  defp gap_class(:lg), do: "gap-5"
  defp gap_class(_gap), do: "gap-4"

  defp group_container_classes(:row), do: "flex h-full min-h-0 flex-row gap-3"
  defp group_container_classes(:column), do: "flex h-full min-h-0 flex-col gap-3"
  defp group_container_classes(:stack), do: "grid h-full min-h-0 gap-3"
  defp group_container_classes(:compact_grid), do: "grid h-full min-h-0 gap-3 sm:grid-cols-2"

  defp group_child_classes(:row), do: "min-w-0 flex-1"
  defp group_child_classes(:column), do: "min-h-0 flex-1"
  defp group_child_classes(:stack), do: "min-h-0"
  defp group_child_classes(:compact_grid), do: "min-h-0"

  defp alarm_strip_status(%{faults: faults}) when faults > 0, do: :crashed
  defp alarm_strip_status(%{alarms: alarms}) when alarms > 0, do: :faulted
  defp alarm_strip_status(_summary), do: :healthy

  defp summary_count(summary, key), do: map_int(summary, key)

  defp summary_timestamp(summary) do
    case Map.get(summary || %{}, :last_transition_at) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp summary_linked(summary) do
    "#{summary_count(summary, :connected)}/#{summary_count(summary, :total)}"
  end

  defp alarm_count(summary, key), do: map_int(summary, key)
  defp alarm_affected(summary), do: map_list(summary, :affected)
  defp lane_machines(lane), do: map_list(lane, :machines)
  defp lane_overflow(lane), do: map_int(lane, :overflow)
  defp registry_machines(registry), do: map_list(registry, :machines)
  defp registry_overflow(registry), do: map_int(registry, :overflow)
  defp event_stream_events(event_stream), do: map_list(event_stream, :events)
  defp event_stream_overflow(event_stream), do: map_int(event_stream, :overflow)

  defp map_int(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> 0
    end
  end

  defp map_int(_map, _key), do: 0

  defp map_list(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_list(value) -> value
      _ -> []
    end
  end

  defp map_list(_map, _key), do: []

  defp summary_cell_classes(:good), do: "bg-[var(--app-good-surface)]"
  defp summary_cell_classes(:warn), do: "bg-[var(--app-warn-surface)]"
  defp summary_cell_classes(:danger), do: "bg-[var(--app-danger-surface)]"
  defp summary_cell_classes(:info), do: "bg-[var(--app-info-surface)]"
  defp summary_cell_classes(:neutral), do: "bg-[var(--app-surface-alt)]"

  defp link_classes(true) do
    "border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--app-good-text)]"
  end

  defp link_classes(false) do
    "border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--app-text)]"
  end

  defp control_button_classes(false) do
    "cursor-not-allowed border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-2.5 py-1.5 font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--app-text-dim)]"
  end

  defp control_button_classes(true) do
    "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-2.5 py-1.5 font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--app-info-text)] transition hover:bg-[#1b3a5c]"
  end

  defp procedure_control_mode(:auto), do: "Auto"
  defp procedure_control_mode(:manual), do: "Manual"
  defp procedure_control_mode(other), do: format_value(other)

  defp procedure_owner_label(:manual_operator), do: "Operator"
  defp procedure_owner_label(:procedure), do: "Procedure"
  defp procedure_owner_label(:manual_takeover_pending), do: "Takeover Pending"
  defp procedure_owner_label(other), do: format_value(other)

  defp procedure_trust_label(:trusted), do: "Trusted"
  defp procedure_trust_label(:invalidated), do: "Invalidated"
  defp procedure_trust_label(other), do: format_value(other)

  defp procedure_runtime_label({:running, :live}), do: "Live"
  defp procedure_runtime_label({:running, :simulation}), do: "Simulation"
  defp procedure_runtime_label(:stopped), do: "Stopped"
  defp procedure_runtime_label(other), do: format_value(other)

  defp procedure_run_policy(:cycle), do: "Cycle"
  defp procedure_run_policy(:once), do: "Once"
  defp procedure_run_policy(other), do: format_value(other)

  defp selected_label(nil), do: "None"
  defp selected_label(entry), do: entry.label

  defp default_procedure_status do
    %{
      topology_scope: :all,
      scope_matches_runtime?: true,
      control_mode: :manual,
      owner_kind: :manual_operator,
      selected_procedure_id: nil,
      run_policy: :once,
      runtime_observed: :stopped,
      runtime_trust_state: :trusted,
      runtime_blockers: [],
      active_run: nil,
      terminal_result: nil,
      pending_intent: %{
        pause_requested?: false,
        abort_requested?: false,
        takeover_requested?: false
      },
      actions: %{
        arm_auto?: false,
        switch_to_manual?: false,
        set_cycle_policy?: false,
        set_once_policy?: false,
        run_selected?: false,
        pause?: false,
        resume?: false,
        abort?: false,
        acknowledge?: false,
        clear_result?: false,
        request_manual_takeover?: false
      }
    }
  end

  defp idle_panel_summary(%{actions: %{run_selected?: true}}, entry) when is_map(entry) do
    "#{entry.label} is selected and ready to run."
  end

  defp idle_panel_summary(%{selected_procedure_id: nil}, _entry) do
    "Select a procedure, arm Auto, then start the selected procedure."
  end

  defp idle_panel_summary(%{control_mode: :manual}, _entry) do
    "Arm Auto before starting the selected procedure."
  end

  defp idle_panel_summary(_status, entry) when is_map(entry) do
    "#{entry.label} is selected, but start conditions are not currently satisfied."
  end

  defp idle_panel_summary(_status, _entry) do
    "Choose a procedure from the catalog to make it the next idle selection."
  end

  defp terminal_result_summary(%{sequence_id: sequence_id, status: status, last_error: nil}) do
    "#{sequence_id || "procedure"} finished with status #{format_value(status)}."
  end

  defp terminal_result_summary(%{sequence_id: sequence_id, status: status, last_error: reason}) do
    "#{sequence_id || "procedure"} finished with status #{format_value(status)}. reason=#{format_value(reason)}"
  end

  defp terminal_result_action(%{actions: %{clear_result?: true}}), do: "clear_result"
  defp terminal_result_action(_status), do: "acknowledge"

  defp terminal_result_label(%{actions: %{clear_result?: true}}), do: "Clear"
  defp terminal_result_label(_status), do: "Acknowledge"

  defp terminal_result_enabled?(%{actions: %{clear_result?: true}}), do: true
  defp terminal_result_enabled?(%{actions: %{acknowledge?: true}}), do: true
  defp terminal_result_enabled?(_status), do: false

  defp terminal_result_button_test(%{actions: %{clear_result?: true}}),
    do: "procedure-clear-result"

  defp terminal_result_button_test(_status), do: "procedure-acknowledge"

  defp procedure_entry_reason(entry) do
    entry.eligibility_reason_text || entry.blocked_reason_text
  end

  defp procedure_selectable?(entry, orchestration_status) do
    entry.active? == false and
      orchestration_status.active_run == nil and
      is_nil(orchestration_status.terminal_result)
  end

  defp operator_feedback_summary(%{kind: :procedure_control} = feedback) do
    action = feedback.action |> to_string() |> String.replace("_", " ")
    target = feedback.target |> to_string()
    "#{target} :: #{action}"
  end

  defp operator_feedback_summary(feedback) do
    machine = feedback.machine_id |> to_string()
    name = feedback.name |> to_string()
    "#{machine} :: skill #{name}"
  end

  defp operator_feedback_detail(%{kind: :procedure_control, status: :pending}),
    do: "dispatching procedure action"

  defp operator_feedback_detail(%{status: :pending}), do: "invoking skill"

  defp operator_feedback_detail(%{status: :ok, detail: detail}),
    do: "reply=#{format_value(detail)}"

  defp operator_feedback_detail(%{status: :error, detail: detail}),
    do: "reason=#{format_value(detail)}"

  defp operator_feedback_classes(:ok),
    do: "border-[var(--app-good-border)] bg-[var(--app-good-surface)]"

  defp operator_feedback_classes(:pending),
    do: "border-[var(--app-info-border)] bg-[var(--app-info-surface)]"

  defp operator_feedback_classes(:error),
    do: "border-[var(--app-danger-border)] bg-[var(--app-danger-surface)]"

  defp attention_summary(machine) do
    [
      if(machine.faults != [], do: "#{length(machine.faults)} fault(s)"),
      if(machine.alarms != [], do: "#{length(machine.alarms)} alarm(s)"),
      if(not machine.connected?, do: "runtime link missing"),
      if(machine.last_signal, do: "last signal #{machine.last_signal}")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "Needs operator review due to current runtime posture."
      parts -> Enum.join(parts, " | ")
    end
  end

  defp event_target(event) do
    event.machine_id || event.topology_id || event.meta[:endpoint_id] || event.meta[:slave] ||
      "system"
  end

  defp event_scope(event) do
    [
      scope_label(:machine, event.machine_id),
      scope_label(:topology, event.topology_id),
      scope_label(:endpoint, event.meta[:endpoint_id] || event.meta[:slave])
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "scope=system"
      parts -> Enum.join(parts, " | ")
    end
  end

  defp scope_label(_label, nil), do: nil
  defp scope_label(label, value), do: "#{label}=#{value}"

  defp event_tags(event) do
    []
    |> maybe_named_event_tag(event)
    |> maybe_event_tag(:reply, event.payload[:reply])
    |> maybe_event_tag(:action, event.payload[:action])
    |> maybe_event_tag(:state, event.payload[:state])
    |> maybe_event_tag(:signal, signal_tag_value(event))
    |> maybe_event_tag(:value, event.payload[:value])
    |> maybe_event_tag(:dependency, event.payload[:dependency])
    |> maybe_event_tag(:bus, event.meta[:bus])
    |> maybe_event_tag(:endpoint, event.meta[:endpoint_id] || event.meta[:slave])
    |> maybe_event_tag(:reason, event.payload[:reason])
    |> Enum.take(4)
  end

  defp maybe_event_tag(tags, _label, nil), do: tags
  defp maybe_event_tag(tags, label, value), do: ["#{label}=#{format_value(value)}" | tags]

  defp maybe_named_event_tag(tags, %{type: :operator_skill_invoked, payload: payload}) do
    maybe_event_tag(tags, :skill, payload[:name])
  end

  defp maybe_named_event_tag(tags, %{type: :operator_skill_failed, payload: payload}) do
    maybe_event_tag(tags, :skill, payload[:name])
  end

  defp maybe_named_event_tag(tags, _event), do: tags

  defp signal_tag_value(%{type: :signal_emitted, payload: payload}), do: payload[:name]
  defp signal_tag_value(%{payload: payload}), do: payload[:signal]

  defp format_skill_name(name), do: name |> to_string() |> String.replace("_", " ")
  defp format_module(nil), do: "module pending"
  defp format_module(module), do: module |> inspect() |> String.replace_prefix("Elixir.", "")

  defp format_event_type(type), do: type |> to_string() |> String.replace("_", " ")
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: truncate(value, 24)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp format_value(value), do: value |> inspect(limit: 4) |> truncate(24)

  defp format_timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_timestamp(_), do: "n/a"

  defp format_age(nil), do: "n/a"

  defp format_age(value) when is_integer(value) do
    diff = max(System.system_time(:millisecond) - value, 0)

    cond do
      diff < 1_000 -> "#{diff} ms ago"
      diff < 60_000 -> "#{div(diff, 1_000)} s ago"
      diff < 3_600_000 -> "#{div(diff, 60_000)} m ago"
      true -> "#{div(diff, 3_600_000)} h ago"
    end
  end

  defp truncate(value, max_length) when byte_size(value) <= max_length, do: value
  defp truncate(value, max_length), do: String.slice(value, 0, max_length - 3) <> "..."

  defp status_tile_label(%Widget{} = node, data) do
    node.options[:label] ||
      node.options[:field] ||
      first_scalar_key(data) ||
      node.binding ||
      :value
      |> humanize_key()
  end

  defp status_tile_value(%Widget{} = node, data) do
    data
    |> extract_scalar(node.options[:field])
    |> format_value()
  end

  defp status_tile_detail(%Widget{} = node, data) do
    case node.options[:field] do
      nil -> "Scalar value selected from the current binding projection."
      field -> "Projected from #{humanize_key(field)}."
    end
    |> maybe_append_detail(Map.get(data, :last_transition_at))
  end

  defp maybe_append_detail(detail, nil), do: detail
  defp maybe_append_detail(detail, timestamp), do: "#{detail} Updated #{format_age(timestamp)}"

  defp value_grid_entries(%Widget{} = node, data) do
    fields =
      case node.options[:fields] do
        fields when is_list(fields) and fields != [] -> fields
        _ -> first_scalar_fields(data, 4)
      end

    Enum.map(fields, fn field ->
      {humanize_key(field), format_value(extract_scalar(data, field))}
    end)
  end

  defp fault_list_items(%Widget{} = node, data) do
    limit =
      case node.options[:limit] do
        value when is_integer(value) and value > 0 -> value
        _ -> 4
      end

    data
    |> extract_fault_items()
    |> Enum.take(limit)
    |> Enum.map(&humanize_fault_item/1)
  end

  defp machine_summary_item(%Widget{} = node, %{machines: machines}) when is_list(machines) do
    index =
      case node.options[:index] do
        value when is_integer(value) and value >= 0 -> value
        _ -> 0
      end

    Enum.at(machines, index)
  end

  defp machine_summary_item(_node, _data), do: nil

  defp skill_button_machine_id(%{machine_id: machine_id}) when not is_nil(machine_id),
    do: to_string(machine_id)

  defp skill_button_machine_id(_data), do: nil

  defp skill_button_skills(%Widget{} = node, %{skills: skills}) when is_list(skills) do
    allowed =
      case node.options[:skills] do
        items when is_list(items) and items != [] -> MapSet.new(items)
        _ -> nil
      end

    skills
    |> Enum.filter(fn skill ->
      is_nil(allowed) or MapSet.member?(allowed, skill.name)
    end)
  end

  defp skill_button_skills(_node, _data), do: []

  defp extract_scalar(data, nil) when is_map(data) do
    case first_scalar_fields(data, 1) do
      [field] -> extract_scalar(data, field)
      _ -> :n_a
    end
  end

  defp extract_scalar(data, field) when is_map(data) do
    Map.get(data, normalize_field(field), Map.get(data, field, :n_a))
  end

  defp extract_scalar(data, _field), do: data

  defp first_scalar_key(data) when is_map(data) do
    data
    |> first_scalar_fields(1)
    |> List.first()
  end

  defp first_scalar_key(_data), do: nil

  defp first_scalar_fields(data, limit) when is_map(data) do
    data
    |> Enum.filter(fn {_key, value} -> scalar_value?(value) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(limit)
  end

  defp first_scalar_fields(_data, _limit), do: []

  defp scalar_value?(value)
       when is_nil(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_binary(value) or is_atom(value),
       do: true

  defp scalar_value?(_value), do: false

  defp extract_fault_items(%{affected: affected}) when is_list(affected), do: affected

  defp extract_fault_items(%{events: events}) when is_list(events),
    do: Enum.map(events, &event_target/1)

  defp extract_fault_items(list) when is_list(list), do: list
  defp extract_fault_items(_data), do: []

  defp humanize_fault_item(item) when is_binary(item), do: item
  defp humanize_fault_item(item) when is_atom(item), do: humanize_key(item)
  defp humanize_fault_item(item), do: format_value(item)

  defp normalize_field(field) when is_binary(field) do
    try do
      String.to_existing_atom(field)
    rescue
      ArgumentError -> field
    end
  end

  defp normalize_field(field), do: field

  defp humanize_key(key) when is_atom(key), do: key |> Atom.to_string() |> humanize_key()

  defp humanize_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.trim()
    |> case do
      "" -> "Value"
      text -> String.capitalize(text)
    end
  end
end
