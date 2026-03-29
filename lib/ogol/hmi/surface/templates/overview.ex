defmodule Ogol.HMI.Surface.Templates.Overview do
  @moduledoc false

  alias Ogol.HMI.{EventLog, SnapshotStore, Surface}
  alias Ogol.Topology.Registry

  @default_event_limit 6

  def build_context(%Surface.Runtime{} = runtime, opts \\ []) do
    event_limit = Keyword.get(opts, :event_limit, @default_event_limit)
    scope = runtime_scope(runtime)
    machines = load_machines(scope)
    summary = dashboard_summary(machines)
    attention = attention_machines(machines)
    all_events = scoped_events(scope)
    events = Enum.take(all_events, event_limit)

    runtime.bindings
    |> Enum.map(fn {name, binding_ref} ->
      {name,
       resolve_binding(
         binding_ref.source,
         scope,
         machines,
         summary,
         attention,
         events,
         all_events
       )}
    end)
    |> Map.new()
  end

  def resolve_skill(context, machine_id, name) do
    with {:ok, machine} <- resolve_machine(context[:machine_registry][:machines], machine_id),
         {:ok, skill_name} <- resolve_skill_name(machine.skills, name) do
      {:ok, machine, skill_name}
    end
  end

  def summary_health(%{machines: machines}), do: summary_health(machines)

  def summary_health(machines) when is_list(machines),
    do: choose_summary_health(Enum.map(machines, & &1.health))

  defp resolve_binding(
         :runtime_summary,
         _scope,
         _machines,
         summary,
         _attention,
         _events,
         _all_events
       ),
       do: summary

  defp resolve_binding(
         {:topology_runtime_summary, _topology_id},
         _scope,
         _machines,
         summary,
         _attention,
         _events,
         _all_events
       ),
       do: summary

  defp resolve_binding(
         :alarm_summary,
         _scope,
         _machines,
         summary,
         attention,
         _events,
         _all_events
       ),
       do: alarm_summary(summary, attention)

  defp resolve_binding(
         {:topology_alarm_summary, _topology_id},
         _scope,
         _machines,
         summary,
         attention,
         _events,
         _all_events
       ),
       do: alarm_summary(summary, attention)

  defp resolve_binding(
         :attention_lane,
         _scope,
         _machines,
         _summary,
         attention,
         _events,
         _all_events
       ),
       do: %{machines: Enum.take(attention, 3), overflow: overflow_count(attention, 3)}

  defp resolve_binding(
         {:topology_attention_lane, _topology_id},
         _scope,
         _machines,
         _summary,
         attention,
         _events,
         _all_events
       ),
       do: %{machines: Enum.take(attention, 3), overflow: overflow_count(attention, 3)}

  defp resolve_binding(
         :machine_registry,
         _scope,
         machines,
         _summary,
         _attention,
         _events,
         _all_events
       ),
       do: %{machines: Enum.take(machines, 4), overflow: overflow_count(machines, 4)}

  defp resolve_binding(
         {:topology_machine_registry, _topology_id},
         _scope,
         machines,
         _summary,
         _attention,
         _events,
         _all_events
       ),
       do: %{machines: Enum.take(machines, 4), overflow: overflow_count(machines, 4)}

  defp resolve_binding(
         :event_stream,
         _scope,
         _machines,
         _summary,
         _attention,
         events,
         all_events
       ),
       do: %{events: events, overflow: max(length(all_events) - length(events), 0)}

  defp resolve_binding(
         {:topology_event_stream, _topology_id},
         _scope,
         _machines,
         _summary,
         _attention,
         events,
         all_events
       ),
       do: %{events: events, overflow: max(length(all_events) - length(events), 0)}

  defp resolve_binding(:ops_links, scope, machines, _summary, _attention, _events, _all_events),
    do: quick_links(scope, machines)

  defp resolve_binding(
         {:topology_links, _topology_id},
         scope,
         machines,
         _summary,
         _attention,
         _events,
         _all_events
       ),
       do: quick_links(scope, machines)

  defp resolve_binding(_other, _scope, _machines, _summary, _attention, _events, _all_events),
    do: %{}

  defp runtime_scope(%Surface.Runtime{} = runtime) do
    runtime.bindings
    |> Map.values()
    |> Enum.find_value(fn binding_ref -> scope_from_source(binding_ref.source) end)
    |> case do
      nil -> :all
      scope -> scope
    end
  end

  defp scope_from_source({binding_type, topology_id})
       when binding_type in [
              :topology_runtime_summary,
              :topology_alarm_summary,
              :topology_attention_lane,
              :topology_machine_registry,
              :topology_event_stream,
              :topology_links
            ] do
    {:topology, topology_id}
  end

  defp scope_from_source(_source), do: nil

  defp load_machines(:all) do
    SnapshotStore.list_machines()
    |> Enum.map(&enrich_machine/1)
  end

  defp load_machines({:topology, topology_id}) do
    topology_machine_ids(topology_id)
    |> Enum.map(&machine_snapshot/1)
    |> Enum.map(&enrich_machine/1)
  end

  defp topology_machine_ids(topology_id) do
    case Registry.active_topology() do
      %{module: module, root: root} ->
        if function_exported?(module, :__ogol_topology__, 0) and
             to_string(root) == to_string(topology_id) do
          module.__ogol_topology__().machines
          |> Enum.map(&Map.fetch!(&1, :name))
        else
          []
        end

      _ ->
        []
    end
  end

  defp machine_snapshot(machine_id) do
    SnapshotStore.get_machine(machine_id) || %{machine_id: machine_id}
  end

  defp enrich_machine(machine) do
    Map.merge(machine, %{
      public_status: Ogol.status(machine.machine_id),
      skills: Ogol.skills(machine.machine_id)
    })
  end

  defp scoped_events(:all), do: EventLog.recent(100) |> Enum.reverse()

  defp scoped_events({:topology, topology_id}) do
    machine_keys =
      topology_id
      |> topology_machine_ids()
      |> Enum.map(&to_string/1)
      |> MapSet.new()

    EventLog.recent(100)
    |> Enum.reverse()
    |> Enum.filter(fn event ->
      event_matches_topology?(event, topology_id, machine_keys)
    end)
  end

  defp event_matches_topology?(event, topology_id, machine_keys) do
    direct_topology_match? = to_string(event.topology_id || "") == to_string(topology_id)

    machine_targets = [
      event.machine_id,
      event.meta[:machine_id],
      event.meta[:dependency],
      event.payload[:dependency]
    ]

    direct_topology_match? or
      Enum.any?(machine_targets, &MapSet.member?(machine_keys, to_string(&1 || "")))
  end

  defp resolve_machine(nil, _machine_id), do: {:error, :machine_unavailable}

  defp resolve_machine(machines, machine_id) do
    case Enum.find(machines, &(to_string(&1.machine_id) == machine_id)) do
      nil -> {:error, :machine_unavailable}
      machine -> {:ok, machine}
    end
  end

  defp resolve_skill_name(skills, name) do
    case Enum.find(skills, &(to_string(&1.name) == name)) do
      nil -> {:error, {:unknown_skill, name}}
      skill -> {:ok, skill.name}
    end
  end

  defp dashboard_summary(machines) do
    %{
      total: length(machines),
      connected: Enum.count(machines, & &1.connected?),
      active: health_count(machines, [:healthy, :running, :waiting, :recovering]),
      running: health_count(machines, [:running]),
      waiting: health_count(machines, [:healthy, :waiting, :recovering]),
      faulted: health_count(machines, [:faulted, :crashed]),
      offline: health_count(machines, [:stopped, :disconnected, :stale]),
      alarms: Enum.reduce(machines, 0, fn machine, acc -> acc + length(machine.alarms) end),
      faults: Enum.reduce(machines, 0, fn machine, acc -> acc + length(machine.faults) end),
      observed_machines:
        Enum.reduce(machines, 0, fn machine, acc -> acc + length(machine.dependencies || []) end),
      last_transition_at: latest_transition(machines)
    }
  end

  defp alarm_summary(summary, attention_machines) do
    %{
      alarms: summary.alarms,
      faults: summary.faults,
      faulted_machines: summary.faulted,
      offline_machines: summary.offline,
      affected:
        attention_machines
        |> Enum.take(3)
        |> Enum.map(&to_string(&1.machine_id))
    }
  end

  defp quick_links({:topology, _topology_id}, machines) do
    [
      %{
        label: "Machine Detail",
        detail: latest_machine_detail(machines),
        path: latest_machine_path(machines),
        disabled: machines == []
      },
      %{
        label: "Topology",
        detail: "Open the currently active topology authoring surface.",
        path: "/studio/topology",
        disabled: false
      }
    ]
  end

  defp quick_links(_scope, machines) do
    [
      %{
        label: "Machine Detail",
        detail: latest_machine_detail(machines),
        path: latest_machine_path(machines),
        disabled: machines == []
      },
      %{
        label: "Surface Launcher",
        detail: "Supervisor and fallback launcher for compiled runtime surfaces.",
        path: "/ops/hmis",
        disabled: false
      }
    ]
  end

  defp latest_machine_path([machine | _rest]), do: "/ops/machines/#{machine.machine_id}"
  defp latest_machine_path([]), do: "/ops/hmis"

  defp latest_machine_detail([machine | _rest]) do
    "#{machine.machine_id} is the first available drill-down target."
  end

  defp latest_machine_detail([]) do
    "Open the surface launcher to inspect the assigned runtime surface."
  end

  defp attention_machines(machines) do
    machines
    |> Enum.filter(
      &(&1.health in [:faulted, :crashed, :stopped, :disconnected, :stale, :recovering])
    )
    |> Enum.sort_by(fn machine ->
      {attention_priority(machine.health), to_string(machine.machine_id)}
    end)
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

  defp overflow_count(items, visible_count), do: max(length(items) - visible_count, 0)

  defp choose_summary_health([]), do: :stopped

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

  defp attention_priority(:faulted), do: 0
  defp attention_priority(:crashed), do: 0
  defp attention_priority(:recovering), do: 1
  defp attention_priority(:disconnected), do: 2
  defp attention_priority(:stale), do: 2
  defp attention_priority(:stopped), do: 3
  defp attention_priority(_status), do: 4
end
