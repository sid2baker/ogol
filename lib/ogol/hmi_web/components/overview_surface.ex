defmodule Ogol.HMIWeb.Components.OverviewSurface do
  use Ogol.HMIWeb, :html

  alias Ogol.HMI.Surface.{Group, Variant, Widget, Zone}
  alias Ogol.HMIWeb.Components.StatusBadge

  attr(:surface, :map, required: true)
  attr(:screen, :map, required: true)
  attr(:variant, :map, required: true)
  attr(:context, :map, required: true)
  attr(:operator_feedback, :any, default: nil)

  def render(assigns) do
    ~H"""
    <section
      data-test={"surface-screen-#{@screen.id}"}
      data-profile={@variant.profile_id}
      class={["grid h-full min-h-0 overflow-hidden", gap_class(@variant.grid.gap)]}
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

  defp operator_feedback_summary(feedback) do
    machine = feedback.machine_id |> to_string()
    name = feedback.name |> to_string()
    "#{machine} :: skill #{name}"
  end

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
