defmodule Ogol.HMI.Surface.Templates.Station do
  @moduledoc false

  alias Ogol.HMI.{EventLog, SnapshotStore, Surface}

  @default_event_limit 8

  def build_context(%Surface.Runtime{} = runtime, opts \\ []) do
    event_limit = Keyword.get(opts, :event_limit, @default_event_limit)

    runtime.bindings
    |> Enum.map(fn {name, binding_ref} ->
      {name, resolve_binding(binding_ref.source, event_limit)}
    end)
    |> Map.new()
  end

  def resolve_skill(context, machine_id, name) do
    with {:ok, machine} <- resolve_machine(context, machine_id),
         {:ok, skill_name} <- resolve_skill_name(machine.skills, name) do
      {:ok, machine, skill_name}
    end
  end

  defp resolve_binding({:machine_status, machine_id}, _event_limit) do
    machine_status(machine_id)
  end

  defp resolve_binding({:machine_alarm_summary, machine_id}, _event_limit) do
    machine_alarm_summary(machine_id)
  end

  defp resolve_binding({:machine_skills, machine_id}, _event_limit) do
    machine = machine_projection(machine_id)

    %{
      machine_id: machine.machine_id,
      connected?: machine.connected?,
      health: machine.health,
      skills: machine.skills
    }
  end

  defp resolve_binding({:machine_summary, machine_id}, _event_limit) do
    %{machines: [machine_projection(machine_id)], overflow: 0}
  end

  defp resolve_binding({:machine_events, machine_id}, event_limit) do
    events =
      machine_events(machine_id)
      |> Enum.take(event_limit)

    %{
      events: events,
      overflow: max(length(machine_events(machine_id)) - event_limit, 0)
    }
  end

  defp resolve_binding({:static_links, links}, _event_limit) when is_list(links), do: links
  defp resolve_binding(links, _event_limit) when is_list(links), do: links
  defp resolve_binding(source, _event_limit), do: source

  defp resolve_machine(context, machine_id) do
    machine_id = to_string(machine_id)

    context
    |> Map.values()
    |> Enum.find(fn
      %{machine_id: current_machine_id, skills: skills}
      when is_list(skills) and not is_nil(current_machine_id) ->
        to_string(current_machine_id) == machine_id

      _other ->
        false
    end)
    |> case do
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

  defp machine_status(machine_id) do
    machine = machine_projection(machine_id)

    machine.public_status
    |> Map.merge(%{
      machine_id: machine.machine_id,
      health: machine.health,
      connected?: machine.connected?,
      current_state: machine.current_state,
      last_signal: machine.last_signal,
      last_transition_at: machine.last_transition_at,
      alarms: machine.alarms,
      faults: machine.faults
    })
  end

  defp machine_alarm_summary(machine_id) do
    machine = machine_projection(machine_id)

    %{
      alarms: length(machine.alarms),
      faults: length(machine.faults),
      faulted_machines: if(machine.health in [:faulted, :crashed], do: 1, else: 0),
      offline_machines: if(machine.connected?, do: 0, else: 1),
      affected:
        if(machine.alarms != [] or machine.faults != [] or not machine.connected?,
          do: [to_string(machine.machine_id)],
          else: []
        )
    }
  end

  defp machine_projection(machine_id) do
    snapshot = SnapshotStore.get_machine(machine_id)
    status = Ogol.status(machine_id)
    skills = Ogol.skills(machine_id)

    %{
      machine_id: machine_id,
      module: first_present(status && status.module, snapshot && snapshot.module),
      current_state:
        first_present(status && status.current_state, snapshot && snapshot.current_state),
      health: first_present(status && status.health, snapshot && snapshot.health, :disconnected),
      connected?:
        first_present(status && status.connected?, snapshot && snapshot.connected?, false),
      last_signal: first_present(status && status.last_signal, snapshot && snapshot.last_signal),
      last_transition_at:
        first_present(
          status && status.last_transition_at,
          snapshot && snapshot.last_transition_at
        ),
      public_status: public_status_map(status),
      alarms: (snapshot && snapshot.alarms) || [],
      faults: (snapshot && snapshot.faults) || [],
      skills: skills,
      restart_count: (snapshot && snapshot.restart_count) || 0
    }
  end

  defp public_status_map(nil), do: %{}

  defp public_status_map(status) do
    Map.merge(
      status.facts,
      Map.merge(
        status.outputs,
        Map.merge(status.fields, %{current_state: status.current_state, health: status.health})
      )
    )
  end

  defp machine_events(machine_id) do
    machine_key = to_string(machine_id)

    EventLog.recent(100)
    |> Enum.reverse()
    |> Enum.filter(fn event ->
      machine_targets = [
        event.machine_id,
        event.topology_id,
        event.meta[:machine_id],
        event.meta[:dependency],
        event.payload[:dependency]
      ]

      Enum.any?(machine_targets, &(to_string(&1 || "") == machine_key))
    end)
  end

  defp first_present(nil, fallback), do: fallback
  defp first_present(value, _fallback), do: value

  defp first_present(nil, nil, fallback), do: fallback
  defp first_present(nil, value, _fallback), do: value
  defp first_present(value, _other, _fallback), do: value
end
