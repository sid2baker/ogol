defmodule Ogol.HMI.Surface.Templates.Overview do
  @moduledoc false

  alias Ogol.HMI.{EventLog, SnapshotStore}

  @default_event_limit 6

  def build_context(opts \\ []) do
    event_limit = Keyword.get(opts, :event_limit, @default_event_limit)
    machines = load_machines()
    summary = dashboard_summary(machines)
    attention = attention_machines(machines)
    all_events = EventLog.recent(100) |> Enum.reverse()
    events = Enum.take(all_events, event_limit)

    %{
      machines: machines,
      runtime_summary: summary,
      alarm_summary: alarm_summary(summary, attention),
      attention_lane: %{machines: Enum.take(attention, 3), overflow: overflow_count(attention, 3)},
      machine_registry: %{machines: Enum.take(machines, 4), overflow: overflow_count(machines, 4)},
      event_stream: %{events: events, overflow: max(length(all_events) - event_limit, 0)},
      ops_links: quick_links(machines)
    }
  end

  def resolve_skill(context, machine_id, name) do
    with {:ok, machine} <- resolve_machine(context.machines, machine_id),
         {:ok, skill_name} <- resolve_skill_name(machine.skills, name) do
      {:ok, machine, skill_name}
    end
  end

  def summary_health(%{machines: machines}), do: summary_health(machines)

  def summary_health(machines) when is_list(machines),
    do: choose_summary_health(Enum.map(machines, & &1.health))

  defp load_machines do
    SnapshotStore.list_machines()
    |> Enum.map(fn machine ->
      Map.merge(machine, %{
        public_status: Ogol.status(machine.machine_id),
        skills: Ogol.skills(machine.machine_id)
      })
    end)
  end

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
        Enum.reduce(machines, 0, fn machine, acc -> acc + length(machine.dependencies) end),
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

  defp quick_links(machines) do
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
