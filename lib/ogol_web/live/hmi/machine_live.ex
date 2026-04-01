defmodule OgolWeb.HMI.MachineLive do
  use OgolWeb, :live_view

  alias Ogol.Runtime.{Bus, CommandGateway, EventLog, Notification, SnapshotStore}
  alias OgolWeb.HMI.MachineCard
  alias OgolWeb.Components.StatusBadge

  @event_limit 20

  @impl true
  def mount(%{"machine_id" => machine_key}, _session, socket) do
    if connected?(socket) do
      :ok = Bus.subscribe(Bus.machine_topic(machine_key))
      :ok = Bus.subscribe(Bus.events_topic())
    end

    machine = resolve_machine(machine_key)

    {:ok,
     socket
     |> assign(:page_title, "Machine #{machine_key}")
     |> assign(
       :page_summary,
       "Public status, invokable skills, and recent notifications for one runtime machine."
     )
     |> assign(:hmi_mode, :ops)
     |> assign(:hmi_nav, :surfaces)
     |> assign(:machine_key, machine_key)
     |> assign(:machine, machine)
     |> assign(:public_status, status_for(machine))
     |> assign(:skills, skills_for(machine))
     |> assign(:event_limit, @event_limit)
     |> assign(:operator_feedback, nil)
     |> assign(:operator_feedback_ref, nil)
     |> assign(:events, machine_events(machine_key, @event_limit))}
  end

  @impl true
  def handle_info({:machine_snapshot_updated, snapshot}, socket) do
    if to_string(snapshot.machine_id) == socket.assigns.machine_key do
      {:noreply,
       socket
       |> assign(:machine, snapshot)
       |> assign(:public_status, status_for(snapshot))
       |> assign(:skills, skills_for(snapshot))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:event_logged, _notification}, socket) do
    {:noreply, assign(socket, :events, machine_events(socket.assigns.machine_key, @event_limit))}
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
  def handle_event("dispatch_control", %{"name" => name}, socket) do
    case resolve_skill(socket.assigns.skills, socket.assigns.machine, name) do
      {:ok, machine, skill_name} ->
        ref = make_ref()
        dispatch_control_async(self(), ref, machine.machine_id, skill_name)

        {:noreply,
         socket
         |> assign(:operator_feedback_ref, ref)
         |> assign(
           :operator_feedback,
           operator_feedback(:pending, machine.machine_id, skill_name, :dispatching)
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:operator_feedback_ref, nil)
         |> assign(
           :operator_feedback,
           operator_feedback(:error, socket.assigns.machine_key, name, reason)
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex flex-col gap-3 border border-white/10 bg-slate-950/85 px-4 py-4 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)] sm:px-5">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <.link navigate={~p"/ops"} class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)] transition hover:text-[var(--app-text)]">
              Operations
            </.link>
            <div class="mt-2 flex flex-wrap items-center gap-3">
              <h2 class="text-2xl font-semibold tracking-[0.04em] text-white">{@machine_key}</h2>
              <StatusBadge.badge status={machine_health(@machine)} />
            </div>
            <p class="mt-2 max-w-3xl text-sm leading-6 text-slate-400">
              {machine_meaning(@machine) || "Focused machine runtime view with direct operator boundary access and scoped event history."}
            </p>
          </div>

          <div class="grid gap-2 sm:grid-cols-3">
            <.headline_stat label="Module" value={machine_module(@machine)} />
            <.headline_stat label="State" value={machine_state(@machine)} />
            <.headline_stat label="Linked" value={machine_connected(@machine)} />
          </div>
        </div>

        <div
          :if={@operator_feedback}
          class={[
            "flex flex-col gap-2 border px-3 py-3 sm:flex-row sm:items-start sm:justify-between",
            operator_feedback_classes(@operator_feedback.status)
          ]}
        >
          <div>
            <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">Operator Path</p>
            <p class="mt-1 text-sm font-semibold text-white">{operator_feedback_summary(@operator_feedback)}</p>
          </div>

          <p class="font-mono text-[11px] text-slate-300 sm:max-w-[28rem] sm:text-right">
            {operator_feedback_detail(@operator_feedback)}
          </p>
        </div>
      </div>

      <div :if={is_nil(@machine)} class="border border-dashed border-white/15 bg-slate-950/70 px-6 py-14 text-center">
        <h3 class="text-lg font-semibold text-white">Machine unavailable</h3>
        <p class="mt-2 text-sm text-slate-400">
          No projected snapshot exists for this machine id yet. Start the machine and this page will populate automatically.
        </p>
      </div>

      <div :if={@machine} class="grid gap-4 2xl:grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)]">
        <div class="space-y-4">
          <MachineCard.card
            machine={@machine}
            status={@public_status}
            skills={@skills}
            controls_enabled?={@machine.connected?}
          />

          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Public Status
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Projected public machine values</h3>
            </div>

            <div class="grid gap-px bg-white/8 xl:grid-cols-3">
              <.data_panel title="Facts" entries={sorted_entries(@public_status.facts)} empty_label="No public facts" />
              <.data_panel title="Fields" entries={sorted_entries(@public_status.fields)} empty_label="No public fields" />
              <.data_panel title="Outputs" entries={sorted_entries(@public_status.outputs)} empty_label="No public outputs" />
            </div>
          </section>

          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Machine Event Stream
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Recent notifications for this machine</h3>
            </div>

            <div class="max-h-[34rem] overflow-y-auto px-3 py-3">
              <div :if={@events == []} class="border border-dashed border-white/10 px-4 py-6 text-sm text-slate-400">
                No machine-scoped notifications yet.
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
        </div>

        <aside class="space-y-4">
          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Public Interface
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Skills, signals, and public status surface</h3>
            </div>

            <div class="grid gap-px bg-white/8">
              <.summary_row label="Skills" value={join_names(@skills)} />
              <.summary_row label="Signals" value={join_names(signal_descriptors(@machine))} />
              <.summary_row label="Status Facts" value={join_names(status_descriptors(@public_status.facts))} />
              <.summary_row label="Status Outputs" value={join_names(status_descriptors(@public_status.outputs))} />
              <.summary_row label="Status Fields" value={join_names(status_descriptors(@public_status.fields))} />
            </div>
          </section>

          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Runtime Posture
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Health, topology, and incident summary</h3>
            </div>

            <div class="grid gap-px bg-white/8">
              <.summary_row label="Connected" value={machine_connected(@machine)} />
              <.summary_row label="Last Signal" value={format_term(@machine.last_signal, "none")} />
              <.summary_row label="Last Transition" value={format_timestamp(@machine.last_transition_at)} />
              <.summary_row label="Restarts" value={to_string(@machine.restart_count)} />
              <.summary_row label="Observed Machines" value={Integer.to_string(length(@machine.dependencies))} />
              <.summary_row label="Adapter Status" value={adapter_status_summary(@machine.adapter_status)} />
            </div>
          </section>

          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Exceptions
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Faults, alarms, and topology summaries</h3>
            </div>

            <div class="grid gap-px bg-white/8">
              <.list_panel title="Faults" entries={fault_entries(@machine.faults)} empty_label="No faults recorded" />
              <.list_panel title="Alarms" entries={fault_entries(@machine.alarms)} empty_label="No alarms recorded" />
              <.list_panel title="Observed Machines" entries={observed_machine_entries(@machine.dependencies)} empty_label="No observed machine summaries" />
            </div>
          </section>
        </aside>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  def headline_stat(assigns) do
    ~H"""
    <div class="border border-white/10 bg-slate-900/80 px-3 py-3">
      <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">{@label}</p>
      <p class="mt-1 text-sm font-semibold text-slate-100">{@value}</p>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:empty_label, :string, required: true)

  def data_panel(assigns) do
    ~H"""
    <section class="bg-slate-900/70 px-4 py-4">
      <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">{@title}</p>

      <div class="mt-3 space-y-2">
        <div :if={@entries == []} class="font-mono text-[11px] text-slate-500">{@empty_label}</div>

        <div :for={{key, value} <- @entries} class="flex items-start justify-between gap-3 text-sm">
          <span class="truncate font-mono uppercase tracking-[0.18em] text-slate-500">{key}</span>
          <span class="max-w-[16rem] text-right text-slate-100">{value}</span>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  def summary_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-4 bg-slate-900/70 px-4 py-3">
      <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">{@label}</p>
      <p class="max-w-[18rem] text-right text-sm font-semibold text-slate-100">{@value}</p>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:empty_label, :string, required: true)

  def list_panel(assigns) do
    ~H"""
    <section class="bg-slate-900/70 px-4 py-4">
      <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">{@title}</p>

      <div class="mt-3 space-y-2">
        <div :if={@entries == []} class="font-mono text-[11px] text-slate-500">{@empty_label}</div>

        <div :for={entry <- @entries} class="border border-white/8 bg-[#05090d] px-3 py-2">
          <p class="text-sm text-slate-100">{entry.primary}</p>
          <p :if={entry.secondary} class="mt-1 font-mono text-[10px] text-slate-500">{entry.secondary}</p>
        </div>
      </div>
    </section>
    """
  end

  defp resolve_machine(machine_key) do
    SnapshotStore.list_machines()
    |> Enum.find(&(to_string(&1.machine_id) == machine_key))
  end

  defp machine_events(machine_key, limit) do
    EventLog.recent(limit * 4)
    |> Enum.filter(&event_matches_machine?(&1, machine_key))
    |> Enum.take(-limit)
  end

  defp event_matches_machine?(%Notification{} = event, machine_key) do
    [event.machine_id, event.topology_id, event.meta[:dependency], event.payload[:dependency]]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn value -> to_string(value) == machine_key end) or
      to_string(event.meta[:machine_id] || "") == machine_key
  end

  defp event_matches_machine?(event, machine_key) do
    to_string(Map.get(event, :machine_id) || "") == machine_key
  end

  defp status_for(nil), do: nil

  defp status_for(machine) do
    %Ogol.Machine.Status{
      machine_id: machine.machine_id,
      module: machine.module,
      current_state: machine.current_state,
      health: machine.health,
      connected?: machine.connected?,
      facts: Map.get(machine, :facts, %{}),
      fields: Map.get(machine, :fields, %{}),
      outputs: Map.get(machine, :outputs, %{}),
      last_signal: machine.last_signal,
      last_transition_at: machine.last_transition_at
    }
  end

  defp skills_for(nil), do: []

  defp skills_for(%{module: module}) when is_atom(module) do
    if function_exported?(module, :skills, 0), do: module.skills(), else: []
  end

  defp skills_for(_machine), do: []

  defp signal_descriptors(%{module: module}) when is_atom(module) do
    if function_exported?(module, :__ogol_contract__, 0) do
      module.__ogol_contract__().signals
    else
      []
    end
  end

  defp signal_descriptors(_machine), do: []

  defp status_descriptors(map) when is_map(map) do
    map
    |> Map.keys()
    |> Enum.sort_by(&to_string/1)
    |> Enum.map(&%{name: &1})
  end

  defp resolve_skill(_skills, nil, name), do: {:error, {:machine_unavailable, name}}

  defp resolve_skill(skills, machine, name) do
    case Enum.find(skills, &(to_string(&1.name) == name)) do
      nil -> {:error, {:unknown_skill, name}}
      skill -> {:ok, machine, skill.name}
    end
  end

  defp dispatch_control_async(owner, ref, machine_id, skill_name) do
    Task.start(fn ->
      feedback =
        case CommandGateway.invoke(machine_id, skill_name) do
          {:ok, reply} -> operator_feedback(:ok, machine_id, skill_name, reply)
          {:error, reason} -> operator_feedback(:error, machine_id, skill_name, reason)
        end

      send(owner, {:operator_control_result, ref, feedback})
    end)
  end

  defp operator_feedback(status, machine_id, name, detail) do
    %{status: status, machine_id: machine_id, name: name, detail: detail}
  end

  defp operator_feedback_summary(feedback) do
    machine = feedback.machine_id |> to_string()
    name = feedback.name |> to_string()
    "#{machine} :: skill #{name}"
  end

  defp operator_feedback_detail(%{status: :pending}) do
    "invoking skill"
  end

  defp operator_feedback_detail(%{status: :ok, detail: detail}) do
    "reply=#{format_value(detail)}"
  end

  defp operator_feedback_detail(%{status: :error, detail: detail}),
    do: "reason=#{format_value(detail)}"

  defp operator_feedback_classes(:ok), do: "border-emerald-400/20 bg-emerald-400/10"
  defp operator_feedback_classes(:pending), do: "border-cyan-400/20 bg-cyan-400/10"
  defp operator_feedback_classes(:error), do: "border-rose-400/25 bg-rose-400/10"

  defp machine_meaning(nil), do: nil
  defp machine_meaning(%{module: nil}), do: nil

  defp machine_meaning(%{module: module}) when is_atom(module) do
    if function_exported?(module, :__ogol_contract__, 0) do
      module.__ogol_contract__().summary
    else
      nil
    end
  end

  defp machine_meaning(_machine), do: nil

  defp machine_module(nil), do: "module pending"
  defp machine_module(%{module: nil}), do: "module pending"

  defp machine_module(%{module: module}),
    do: module |> inspect() |> String.replace_prefix("Elixir.", "")

  defp machine_state(nil), do: "unknown"
  defp machine_state(%{current_state: current_state}), do: format_term(current_state, "unknown")

  defp machine_connected(nil), do: "offline"
  defp machine_connected(%{connected?: true}), do: "linked"
  defp machine_connected(%{connected?: false}), do: "offline"

  defp machine_health(nil), do: :stopped
  defp machine_health(%{health: health}), do: health

  defp sorted_entries(map) when map == %{}, do: []

  defp sorted_entries(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), format_value(value)} end)
  end

  defp fault_entries(items) when items in [[], nil], do: []

  defp fault_entries(items) do
    Enum.map(items, fn item ->
      reason = Map.get(item, :reason) || Map.get(item, "reason") || :unknown
      at = Map.get(item, :at) || Map.get(item, "at")
      %{primary: format_value(reason), secondary: format_timestamp(at)}
    end)
  end

  defp observed_machine_entries(dependencies) when dependencies in [[], nil], do: []

  defp observed_machine_entries(dependencies) do
    Enum.map(dependencies, fn dependency ->
      name = Map.get(dependency, :name) || Map.get(dependency, "name") || :dependency

      detail =
        Map.get(dependency, :state) || Map.get(dependency, "state") ||
          Map.get(dependency, :health) || Map.get(dependency, "health") ||
          Map.get(dependency, :last_signal) || Map.get(dependency, "last_signal")

      meta =
        [
          Map.get(dependency, :health) || Map.get(dependency, "health"),
          Map.get(dependency, :last_reason) || Map.get(dependency, "last_reason")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.map_join(" | ", &format_value/1)

      %{primary: "#{name}: #{format_value(detail || :observed)}", secondary: blank_to_nil(meta)}
    end)
  end

  defp join_names(items) when items == [], do: "none"
  defp join_names(items), do: Enum.map_join(items, ", ", &to_string(&1.name))

  defp adapter_status_summary(map) when map == %{}, do: "no adapter status"

  defp adapter_status_summary(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{format_value(value)}" end)
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
    |> Enum.take(5)
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

  defp format_event_type(type), do: type |> to_string() |> String.replace("_", " ")

  defp format_term(nil, fallback), do: fallback
  defp format_term(value, _fallback) when is_atom(value), do: Atom.to_string(value)
  defp format_term(value, _fallback), do: format_value(value)

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: truncate(value, 40)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp format_value(value), do: value |> inspect(limit: 6) |> truncate(40)

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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
