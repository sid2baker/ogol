defmodule Ogol.HMIWeb.OverviewLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.{Bus, CommandGateway, EventLog, SnapshotStore}
  alias Ogol.Machine.Info
  alias Ogol.HMIWeb.Components.{MachineCard, StatusBadge}

  @event_limit 14

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Bus.subscribe(Bus.overview_topic())
      :ok = Bus.subscribe(Bus.events_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign(:event_limit, @event_limit)
     |> assign(:operator_feedback, nil)
     |> assign(:operator_feedback_ref, nil)
     |> assign(:machines, SnapshotStore.list_machines())
     |> assign(:events, EventLog.recent(@event_limit))}
  end

  @impl true
  def handle_info({:machine_snapshot_updated, _snapshot}, socket) do
    {:noreply, assign(socket, :machines, SnapshotStore.list_machines())}
  end

  def handle_info({:event_logged, _notification}, socket) do
    {:noreply, assign(socket, :events, EventLog.recent(@event_limit))}
  end

  def handle_info({:operator_control_result, ref, feedback}, socket) do
    if socket.assigns.operator_feedback_ref == ref do
      {:noreply,
       socket
       |> assign(:operator_feedback_ref, nil)
       |> assign(:operator_feedback, feedback)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event(
        "dispatch_control",
        %{"kind" => kind, "machine_id" => machine_id, "name" => name},
        socket
      ) do
    case resolve_control(socket.assigns.machines, machine_id, kind, name) do
      {:ok, machine, control_kind, control_name} ->
        ref = make_ref()

        dispatch_control_async(self(), ref, machine.machine_id, control_kind, control_name)

        {:noreply,
         socket
         |> assign(:operator_feedback_ref, ref)
         |> assign(
           :operator_feedback,
           operator_feedback(
             :pending,
             machine.machine_id,
             control_kind,
             control_name,
             :dispatching
           )
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:operator_feedback_ref, nil)
         |> assign(
           :operator_feedback,
           operator_feedback(:error, machine_id, kind, name, reason)
         )}
    end
  end

  @impl true
  def render(assigns) do
    assigns = Map.put(assigns, :summary, dashboard_summary(assigns.machines, assigns.events))

    ~H"""
    <section class="grid gap-4 2xl:grid-cols-[minmax(0,1.7fr)_26rem]">
      <div class="space-y-4">
        <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
          <div class="border-b border-white/10 px-4 py-4 sm:px-5">
            <div class="grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_minmax(0,0.95fr)]">
              <div>
                <div class="flex flex-wrap items-center gap-3">
                  <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                    Operations Overview
                  </p>
                  <StatusBadge.badge status={summary_health(@machines)} />
                </div>
                <h2 class="mt-2 text-2xl font-semibold tracking-[0.04em] text-white">
                  Dense runtime surface for machine supervision
                </h2>
                <p class="mt-2 max-w-3xl text-sm leading-6 text-slate-400">
                  Current state, signal traffic, and incident posture compressed into one operator-facing console.
                </p>
              </div>

              <div class="grid gap-2 sm:grid-cols-3">
                <div class="border border-white/10 bg-slate-900/80 px-3 py-3">
                  <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">Latest Event</p>
                  <p class="mt-1 truncate text-sm font-semibold text-slate-100">
                    {last_event_label(@summary.last_event)}
                  </p>
                  <p class="mt-1 font-mono text-[11px] text-slate-500">
                    {last_event_target(@summary.last_event)}
                  </p>
                </div>
                <div class="border border-white/10 bg-slate-900/80 px-3 py-3">
                  <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">Latest Transition</p>
                  <p class="mt-1 text-sm font-semibold text-slate-100">{format_age(@summary.last_transition_at)}</p>
                  <p class="mt-1 font-mono text-[11px] text-slate-500">{format_timestamp(@summary.last_transition_at)}</p>
                </div>
                <div class="border border-white/10 bg-slate-900/80 px-3 py-3">
                  <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">Linked Ratio</p>
                  <p class="mt-1 text-sm font-semibold text-slate-100">
                    {@summary.connected}/{@summary.total}
                  </p>
                  <p class="mt-1 font-mono text-[11px] text-slate-500">{link_ratio(@summary.connected, @summary.total)}</p>
                </div>
              </div>
            </div>

            <div
              :if={@operator_feedback}
              class={[
                "mt-4 flex flex-col gap-2 border px-3 py-3 sm:flex-row sm:items-start sm:justify-between",
                operator_feedback_classes(@operator_feedback.status)
              ]}
            >
              <div>
                <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">
                  Operator Path
                </p>
                <p class="mt-1 text-sm font-semibold text-white">
                  {operator_feedback_summary(@operator_feedback)}
                </p>
              </div>

              <p class="font-mono text-[11px] text-slate-300 sm:max-w-[24rem] sm:text-right">
                {operator_feedback_detail(@operator_feedback)}
              </p>
            </div>
          </div>

          <div class="grid gap-px bg-white/8 sm:grid-cols-2 xl:grid-cols-6">
            <.metric_tile label="Fleet" value={@summary.total} detail="registered units" tone="slate" />
            <.metric_tile label="Linked" value={@summary.connected} detail="active runtime links" tone="emerald" />
            <.metric_tile label="Active" value={@summary.active} detail="ready or running" tone="cyan" />
            <.metric_tile label="Running" value={@summary.running} detail="in motion now" tone="emerald" />
            <.metric_tile label="Alerts" value={@summary.faulted} detail="faulted or crashed" tone="rose" />
            <.metric_tile label="Signals" value={length(@events)} detail="recent notifications" tone="amber" />
          </div>
        </section>

        <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
          <div class="flex flex-col gap-4 border-b border-white/10 px-4 py-4 sm:px-5 xl:flex-row xl:items-end xl:justify-between">
            <div>
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Machine Registry
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Runtime cells, condensed for line monitoring</h3>
              <p class="mt-1 text-sm text-slate-400">
                State, I/O density, child activity, and restart posture in a tighter card footprint.
              </p>
            </div>

            <div class="flex flex-wrap gap-2">
              <.status_counter label="Running" count={@summary.running} tone={:running} />
              <.status_counter label="Ready" count={@summary.waiting} tone={:waiting} />
              <.status_counter label="Faulted" count={@summary.faulted} tone={:faulted} />
              <.status_counter label="Offline" count={@summary.offline} tone={:offline} />
            </div>
          </div>

          <div class="p-3 sm:p-4">
            <div :if={@machines == []} class="border border-dashed border-white/15 bg-slate-900/55 px-6 py-14 text-center">
              <h3 class="text-lg font-semibold text-white">No machines running yet</h3>
              <p class="mt-2 text-sm text-slate-400">
                Start a generated Ogol machine and it will appear here automatically.
              </p>
            </div>

            <div :if={@machines != []} class="grid gap-3 2xl:grid-cols-2">
              <MachineCard.card
                :for={machine <- @machines}
                machine={machine}
                request_names={request_names(machine)}
                event_names={event_names(machine)}
                controls_enabled?={machine.connected?}
              />
            </div>
          </div>
        </section>
      </div>

      <aside class="space-y-4">
        <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
          <div class="border-b border-white/10 px-4 py-4">
            <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
              System Breakdown
            </p>
            <h3 class="mt-1 text-lg font-semibold text-white">Fleet density at a glance</h3>
          </div>

          <div class="divide-y divide-white/8">
            <.breakdown_row label="Telemetry Footprint" value={"#{@summary.data_points} facts / fields / outputs"} accent="cyan" />
            <.breakdown_row label="Child Cells" value={to_string(@summary.children)} accent="amber" />
            <.breakdown_row label="Alarm Records" value={to_string(@summary.alarms)} accent="amber" />
            <.breakdown_row label="Fault Records" value={to_string(@summary.faults)} accent="rose" />
            <.breakdown_row label="Event Window" value={"#{length(@events)} of #{@event_limit} used"} accent="slate" />
            <.breakdown_row label="Latest Activity" value={last_event_label(@summary.last_event)} accent="emerald" />
          </div>
        </section>

        <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
          <div class="flex items-center justify-between border-b border-white/10 px-4 py-4">
            <div>
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Event Log
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Recent runtime notifications</h3>
            </div>

            <span class="border border-white/10 bg-slate-900/80 px-3 py-1 font-mono text-[10px] uppercase tracking-[0.28em] text-slate-300">
              {@event_limit} latest
            </span>
          </div>

          <div class="max-h-[calc(100vh-20rem)] overflow-y-auto px-3 py-3">
            <div :if={@events == []} class="border border-dashed border-white/10 px-4 py-6 text-sm text-slate-400">
              No runtime notifications yet.
            </div>

            <div :if={@events != []} class="space-y-2">
              <article
                :for={event <- Enum.reverse(@events)}
                class="border border-white/8 bg-slate-900/65 px-3 py-3"
              >
                <div class="flex items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <p class="truncate text-sm font-semibold text-slate-100">{format_event_type(event.type)}</p>
                      <span class="border border-white/10 bg-slate-950/80 px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.24em] text-slate-400">
                        {event_target(event)}
                      </span>
                    </div>

                    <p class="mt-1 truncate font-mono text-[11px] text-slate-500">{event_scope(event)}</p>

                    <div class="mt-2 flex flex-wrap gap-1.5">
                      <span
                        :for={tag <- event_tags(event)}
                        class="border border-white/8 bg-[#05090d] px-2 py-0.5 font-mono text-[10px] text-slate-300"
                      >
                        {tag}
                      </span>
                    </div>
                  </div>

                  <div class="shrink-0 text-right">
                    <p class="font-mono text-[11px] text-slate-500">{format_timestamp(event.occurred_at)}</p>
                    <p class="mt-1 font-mono text-[10px] text-slate-600">{format_age(event.occurred_at)}</p>
                  </div>
                </div>
              </article>
            </div>
          </div>
        </section>
      </aside>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)
  attr(:tone, :string, default: "slate")

  def metric_tile(assigns) do
    ~H"""
    <div class={["px-4 py-3", metric_tone_classes(@tone)]}>
      <p class="font-mono text-[10px] uppercase tracking-[0.3em] text-slate-500">{@label}</p>
      <p class="mt-1 text-2xl font-semibold text-white">{@value}</p>
      <p class="mt-1 text-[11px] text-slate-400">{@detail}</p>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:tone, :atom, default: :neutral)

  def status_counter(assigns) do
    ~H"""
    <div class={["border px-3 py-2", counter_tone_classes(@tone)]}>
      <p class="font-mono text-[10px] uppercase tracking-[0.28em]">{@label}</p>
      <p class="mt-1 text-lg font-semibold">{@count}</p>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:accent, :string, default: "slate")

  def breakdown_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 px-4 py-3">
      <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">{@label}</p>
      <p class={["max-w-[14rem] text-right text-sm font-semibold", breakdown_accent_classes(@accent)]}>
        {@value}
      </p>
    </div>
    """
  end

  defp request_names(machine), do: control_names(machine.module, :request)
  defp event_names(machine), do: control_names(machine.module, :event)

  defp control_names(nil, _kind), do: []

  defp control_names(module, :request) do
    module
    |> Info.requests()
    |> Enum.map(& &1.name)
    |> Enum.sort_by(&to_string/1)
  end

  defp control_names(module, :event) do
    module
    |> Info.events()
    |> Enum.map(& &1.name)
    |> Enum.sort_by(&to_string/1)
  end

  defp resolve_control(machines, machine_id, kind, name) do
    with {:ok, control_kind} <- parse_control_kind(kind),
         {:ok, machine} <- resolve_machine(machines, machine_id),
         {:ok, control_name} <- resolve_control_name(machine.module, control_kind, name) do
      {:ok, machine, control_kind, control_name}
    end
  end

  defp parse_control_kind("request"), do: {:ok, :request}
  defp parse_control_kind("event"), do: {:ok, :event}
  defp parse_control_kind(other), do: {:error, {:unknown_operator_action, other}}

  defp resolve_machine(machines, machine_id) do
    case Enum.find(machines, &(to_string(&1.machine_id) == machine_id)) do
      nil -> {:error, :machine_unavailable}
      machine -> {:ok, machine}
    end
  end

  defp resolve_control_name(nil, _kind, _name), do: {:error, :module_unavailable}

  defp resolve_control_name(module, kind, name) do
    case Enum.find(control_names(module, kind), &(to_string(&1) == name)) do
      nil -> {:error, {:unknown_operator_action, kind, name}}
      control_name -> {:ok, control_name}
    end
  end

  defp operator_feedback(status, machine_id, kind, name, detail) do
    %{status: status, machine_id: machine_id, kind: kind, name: name, detail: detail}
  end

  defp dispatch_control_async(owner, ref, machine_id, :request, control_name) do
    Task.start(fn ->
      feedback =
        case CommandGateway.request(machine_id, control_name) do
          {:ok, reply} ->
            operator_feedback(:ok, machine_id, :request, control_name, reply)

          {:error, reason} ->
            operator_feedback(:error, machine_id, :request, control_name, reason)
        end

      send(owner, {:operator_control_result, ref, feedback})
    end)
  end

  defp dispatch_control_async(owner, ref, machine_id, :event, control_name) do
    Task.start(fn ->
      feedback =
        case CommandGateway.event(machine_id, control_name) do
          :ok -> operator_feedback(:ok, machine_id, :event, control_name, :queued)
          {:error, reason} -> operator_feedback(:error, machine_id, :event, control_name, reason)
        end

      send(owner, {:operator_control_result, ref, feedback})
    end)
  end

  defp operator_feedback_summary(feedback) do
    machine = feedback.machine_id |> to_string()
    kind = feedback.kind |> format_feedback_kind()
    name = feedback.name |> to_string()
    "#{machine} :: #{kind} #{name}"
  end

  defp operator_feedback_detail(%{status: :pending, kind: :request}) do
    "waiting for machine reply"
  end

  defp operator_feedback_detail(%{status: :pending, kind: :event}) do
    "dispatching to machine mailbox"
  end

  defp operator_feedback_detail(%{status: :ok, kind: :request, detail: detail}) do
    "reply=#{format_value(detail)}"
  end

  defp operator_feedback_detail(%{status: :ok, kind: :event}), do: "accepted by gateway"

  defp operator_feedback_detail(%{status: :error, detail: detail}),
    do: "reason=#{format_value(detail)}"

  defp format_feedback_kind(:request), do: "request"
  defp format_feedback_kind(:event), do: "event"
  defp format_feedback_kind(kind), do: to_string(kind)

  defp operator_feedback_classes(:ok) do
    "border-emerald-400/20 bg-emerald-400/10"
  end

  defp operator_feedback_classes(:pending) do
    "border-cyan-400/20 bg-cyan-400/10"
  end

  defp operator_feedback_classes(:error) do
    "border-rose-400/25 bg-rose-400/10"
  end

  defp summary_health([]), do: :stopped
  defp summary_health(machines), do: machines |> Enum.map(& &1.health) |> choose_summary_health()

  defp choose_summary_health(statuses) do
    cond do
      Enum.any?(statuses, &(&1 in [:crashed, :faulted])) -> :crashed
      Enum.any?(statuses, &(&1 == :recovering)) -> :recovering
      Enum.any?(statuses, &(&1 == :running)) -> :running
      Enum.any?(statuses, &(&1 == :waiting)) -> :waiting
      Enum.any?(statuses, &(&1 == :healthy)) -> :healthy
      true -> :stopped
    end
  end

  defp dashboard_summary(machines, events) do
    %{
      total: length(machines),
      connected: Enum.count(machines, & &1.connected?),
      active: health_count(machines, [:healthy, :running, :waiting, :recovering]),
      running: health_count(machines, [:running]),
      waiting: health_count(machines, [:healthy, :waiting, :recovering]),
      faulted: health_count(machines, [:faulted, :crashed]),
      offline: health_count(machines, [:stopped, :disconnected, :stale]),
      data_points:
        Enum.reduce(machines, 0, fn machine, acc ->
          acc + map_size(machine.facts) + map_size(machine.fields) + map_size(machine.outputs)
        end),
      alarms: Enum.reduce(machines, 0, fn machine, acc -> acc + length(machine.alarms) end),
      faults: Enum.reduce(machines, 0, fn machine, acc -> acc + length(machine.faults) end),
      children: Enum.reduce(machines, 0, fn machine, acc -> acc + length(machine.children) end),
      last_event: List.last(events),
      last_transition_at: latest_transition(machines)
    }
  end

  defp health_count(machines, states), do: Enum.count(machines, &(&1.health in states))

  defp latest_transition(machines) do
    machines
    |> Enum.map(& &1.last_transition_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      timestamps -> Enum.max(timestamps)
    end
  end

  defp metric_tone_classes("emerald"), do: "bg-emerald-400/5"
  defp metric_tone_classes("cyan"), do: "bg-cyan-400/5"
  defp metric_tone_classes("amber"), do: "bg-amber-400/5"
  defp metric_tone_classes("rose"), do: "bg-rose-400/5"
  defp metric_tone_classes(_tone), do: "bg-slate-900/80"

  defp counter_tone_classes(:running),
    do: "border-emerald-400/25 bg-emerald-400/10 text-emerald-50"

  defp counter_tone_classes(:waiting), do: "border-amber-400/25 bg-amber-400/10 text-amber-50"
  defp counter_tone_classes(:faulted), do: "border-rose-400/25 bg-rose-400/10 text-rose-50"
  defp counter_tone_classes(:offline), do: "border-slate-400/20 bg-slate-400/10 text-slate-100"
  defp counter_tone_classes(:neutral), do: "border-white/10 bg-slate-900/70 text-slate-100"

  defp breakdown_accent_classes("emerald"), do: "text-emerald-50"
  defp breakdown_accent_classes("amber"), do: "text-amber-50"
  defp breakdown_accent_classes("rose"), do: "text-rose-50"
  defp breakdown_accent_classes("cyan"), do: "text-cyan-50"
  defp breakdown_accent_classes(_accent), do: "text-slate-100"

  defp last_event_label(nil), do: "none"
  defp last_event_label(event), do: format_event_type(event.type)

  defp last_event_target(nil), do: "scope=system"
  defp last_event_target(event), do: event_target(event)

  defp link_ratio(_connected, 0), do: "no registered units"
  defp link_ratio(connected, total), do: "#{round(connected / total * 100)}% linked"

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
    |> maybe_event_tag(:child, event.payload[:child])
    |> maybe_event_tag(:bus, event.meta[:bus])
    |> maybe_event_tag(:endpoint, event.meta[:endpoint_id] || event.meta[:slave])
    |> maybe_event_tag(:reason, event.payload[:reason])
    |> Enum.take(4)
  end

  defp maybe_event_tag(tags, _label, nil), do: tags
  defp maybe_event_tag(tags, label, value), do: ["#{label}=#{format_value(value)}" | tags]

  defp maybe_named_event_tag(tags, %{type: :operator_request_sent, payload: payload}) do
    maybe_event_tag(tags, :request, payload[:name])
  end

  defp maybe_named_event_tag(tags, %{type: :operator_event_sent, payload: payload}) do
    maybe_event_tag(tags, :event, payload[:name])
  end

  defp maybe_named_event_tag(tags, %{type: :operator_action_failed, payload: payload}) do
    maybe_event_tag(tags, payload[:action] || :action, payload[:name])
  end

  defp maybe_named_event_tag(tags, _event), do: tags

  defp signal_tag_value(%{type: :signal_emitted, payload: payload}), do: payload[:name]
  defp signal_tag_value(%{payload: payload}), do: payload[:signal]

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
end
