defmodule Ogol.HMI.Projector do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.{
    Bus,
    EventLog,
    HardwareSnapshot,
    MachineSnapshot,
    Notification,
    SnapshotStore,
    TopologySnapshot
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def project(%Notification{} = notification) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:project, notification})
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:project, %Notification{} = notification}, state) do
    EventLog.append(notification)
    Bus.broadcast(Bus.events_topic(), {:event_logged, notification})
    apply_notification(notification)
    {:noreply, state}
  end

  defp apply_notification(%Notification{type: :machine_started} = notification) do
    existing = existing_machine(notification.machine_id)
    runtime = runtime_snapshot(notification.meta[:pid])

    snapshot =
      %MachineSnapshot{
        machine_id: notification.machine_id,
        module: notification.payload[:module] || existing.module,
        current_state: Map.get(runtime, :current_state) || existing.current_state,
        health:
          infer_health(
            Map.get(runtime, :current_state) || existing.current_state,
            existing.health
          ),
        last_signal: existing.last_signal,
        last_transition_at: Map.get(runtime, :last_transition_at) || existing.last_transition_at,
        restart_count: existing.restart_count,
        connected?: true,
        facts: Map.get(runtime, :facts) || existing.facts,
        fields: Map.get(runtime, :fields) || existing.fields,
        outputs: Map.get(runtime, :outputs) || existing.outputs,
        alarms: existing.alarms,
        faults: existing.faults,
        dependencies: existing.dependencies,
        adapter_status: existing.adapter_status,
        meta: Map.put(existing.meta, :last_started_at, notification.occurred_at)
      }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :state_entered} = notification) do
    existing = existing_machine(notification.machine_id)
    runtime = runtime_snapshot(notification.meta[:pid])

    current_state =
      notification.payload[:state] || Map.get(runtime, :current_state) || existing.current_state

    snapshot = %MachineSnapshot{
      existing
      | module: notification.payload[:module] || existing.module,
        current_state: current_state,
        health: infer_health(current_state, existing.health),
        last_transition_at: notification.occurred_at,
        connected?: true,
        facts: Map.get(runtime, :facts) || existing.facts,
        fields: Map.get(runtime, :fields) || existing.fields,
        outputs: Map.get(runtime, :outputs) || existing.outputs
    }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :signal_emitted} = notification) do
    existing = existing_machine(notification.machine_id)
    runtime = runtime_snapshot(notification.meta[:pid])

    snapshot = %MachineSnapshot{
      existing
      | last_signal: notification.payload[:name],
        connected?: true,
        facts: Map.get(runtime, :facts) || existing.facts,
        fields: Map.get(runtime, :fields) || existing.fields,
        outputs: Map.get(runtime, :outputs) || existing.outputs
    }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :dependency_state_entered} = notification) do
    existing = existing_topology(notification.topology_id, notification.machine_id)
    dependency = notification.payload[:dependency]
    dependency_state = notification.payload[:state]
    dependency_pid = notification.meta[:dependency_pid]

    snapshot = %TopologySnapshot{
      existing
      | connected?: true,
        dependencies:
          put_dependency_summary(existing.dependencies, dependency, %{
            state: dependency_state,
            health: infer_health(dependency_state, :healthy),
            pid: dependency_pid
          })
    }

    SnapshotStore.put_topology(snapshot)

    Bus.broadcast(
      Bus.topology_topic(snapshot.topology_id),
      {:topology_snapshot_updated, snapshot}
    )
  end

  defp apply_notification(%Notification{type: :dependency_signal_emitted} = notification) do
    existing = existing_topology(notification.topology_id, notification.machine_id)
    dependency = notification.payload[:dependency]
    signal = notification.payload[:signal]

    snapshot = %TopologySnapshot{
      existing
      | connected?: true,
        dependencies:
          put_dependency_summary(existing.dependencies, dependency, %{
            last_signal: signal,
            health: :healthy
          })
    }

    SnapshotStore.put_topology(snapshot)

    Bus.broadcast(
      Bus.topology_topic(snapshot.topology_id),
      {:topology_snapshot_updated, snapshot}
    )
  end

  defp apply_notification(%Notification{type: :dependency_status_updated} = notification) do
    existing = existing_topology(notification.topology_id, notification.machine_id)
    dependency = notification.payload[:dependency]
    item = notification.payload[:item]
    value = notification.payload[:value]

    dependency_attrs =
      Enum.find(existing.dependencies, %{}, fn attrs ->
        to_string(attrs[:name] || attrs["name"]) == to_string(dependency)
      end)

    status_values =
      dependency_attrs
      |> Map.get(:status, %{})
      |> Map.put(item, value)

    snapshot = %TopologySnapshot{
      existing
      | connected?: true,
        dependencies:
          put_dependency_summary(existing.dependencies, dependency, %{
            status: status_values,
            health: dependency_attrs[:health] || :healthy
          })
    }

    SnapshotStore.put_topology(snapshot)

    Bus.broadcast(
      Bus.topology_topic(snapshot.topology_id),
      {:topology_snapshot_updated, snapshot}
    )
  end

  defp apply_notification(%Notification{type: :dependency_down} = notification) do
    existing = existing_topology(notification.topology_id, notification.machine_id)
    dependency = notification.payload[:dependency]
    reason = notification.payload[:reason]

    snapshot = %TopologySnapshot{
      existing
      | connected?: true,
        dependencies:
          put_dependency_summary(existing.dependencies, dependency, %{
            health: :crashed,
            last_reason: reason
          }),
        restart_summary:
          Map.update(existing.restart_summary, dependency, %{count: 1}, fn summary ->
            Map.update(summary, :count, 1, &(&1 + 1))
          end)
    }

    SnapshotStore.put_topology(snapshot)

    Bus.broadcast(
      Bus.topology_topic(snapshot.topology_id),
      {:topology_snapshot_updated, snapshot}
    )
  end

  defp apply_notification(%Notification{type: :machine_stopped} = notification) do
    existing = existing_machine(notification.machine_id)

    snapshot =
      %MachineSnapshot{
        existing
        | health: :stopped,
          connected?: false,
          meta: Map.put(existing.meta, :stop_reason, notification.payload[:reason])
      }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :machine_down} = notification) do
    existing = existing_machine(notification.machine_id)

    snapshot =
      %MachineSnapshot{
        existing
        | health: :crashed,
          connected?: false,
          restart_count: existing.restart_count + 1,
          faults: [
            %{reason: notification.payload[:reason], at: notification.occurred_at}
            | existing.faults
          ]
      }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :adapter_feedback} = notification) do
    bus = notification.meta[:bus] || :unknown
    endpoint_id = notification.meta[:endpoint_id] || notification.meta[:slave] || :unknown
    existing = existing_hardware(bus, endpoint_id)
    runtime = runtime_snapshot(notification.meta[:pid])

    observed_signals =
      case notification.payload do
        %{signal: signal, value: value} when is_atom(signal) ->
          Map.put(existing.observed_signals, signal, value)

        _ ->
          existing.observed_signals
      end

    snapshot =
      %HardwareSnapshot{
        existing
        | connected?: true,
          last_feedback_at: notification.occurred_at,
          observed_signals: observed_signals,
          status: Map.merge(existing.status, Map.take(notification.meta, [:kind, :source]))
      }

    SnapshotStore.put_hardware(snapshot)
    Bus.broadcast(Bus.hardware_topic(bus, endpoint_id), {:hardware_snapshot_updated, snapshot})
    maybe_update_machine_from_runtime(notification.machine_id, runtime)
  end

  defp apply_notification(%Notification{type: :topology_ready} = notification) do
    existing = existing_topology(notification.topology_id, notification.machine_id)

    snapshot =
      %TopologySnapshot{
        existing
        | connected?: true,
          meta:
            Map.merge(
              existing.meta,
              Map.take(notification.meta, [:pid, :root_pid, :supervisor])
            )
      }

    SnapshotStore.put_topology(snapshot)

    Bus.broadcast(
      Bus.topology_topic(snapshot.topology_id),
      {:topology_snapshot_updated, snapshot}
    )
  end

  defp apply_notification(_notification), do: :ok

  defp broadcast_machine(snapshot) do
    Bus.broadcast(Bus.overview_topic(), {:machine_snapshot_updated, snapshot})
    Bus.broadcast(Bus.machine_topic(snapshot.machine_id), {:machine_snapshot_updated, snapshot})
  end

  defp existing_machine(machine_id) do
    case SnapshotStore.get_machine(machine_id) do
      %MachineSnapshot{} = snapshot -> snapshot
      nil -> %MachineSnapshot{machine_id: machine_id, health: :stopped}
    end
  end

  defp existing_topology(topology_id, root_machine_id) do
    case SnapshotStore.get_topology(topology_id) do
      %TopologySnapshot{} = snapshot ->
        snapshot

      nil ->
        %TopologySnapshot{
          topology_id: topology_id,
          root_machine_id: root_machine_id,
          health: :healthy,
          connected?: false
        }
    end
  end

  defp existing_hardware(bus, endpoint_id) do
    case SnapshotStore.get_hardware(bus, endpoint_id) do
      %HardwareSnapshot{} = snapshot -> snapshot
      nil -> %HardwareSnapshot{bus: bus, endpoint_id: endpoint_id, connected?: false}
    end
  end

  defp put_dependency_summary(dependencies, dependency_name, attrs) do
    dependency_name = to_string(dependency_name)

    dependencies
    |> Map.new(fn dependency ->
      {to_string(dependency[:name] || dependency["name"]), dependency}
    end)
    |> Map.update(dependency_name, Map.put(attrs, :name, dependency_name), &Map.merge(&1, attrs))
    |> Map.values()
    |> Enum.sort_by(&to_string(&1[:name] || &1["name"]))
  end

  defp infer_health(state, _current) when state in [:running], do: :running
  defp infer_health(state, _current) when state in [:idle, :waiting], do: :waiting
  defp infer_health(state, _current) when state in [:fault, :faulted], do: :faulted
  defp infer_health(_state, current) when current in [:crashed, :faulted], do: current
  defp infer_health(_state, _current), do: :healthy

  defp runtime_snapshot(pid) when is_pid(pid) do
    case safe_get_state(pid) do
      {state_name, data} ->
        %{
          current_state: state_name,
          facts: data.facts,
          fields: data.fields,
          outputs: data.outputs,
          last_transition_at: System.system_time(:millisecond)
        }

      _ ->
        %{}
    end
  end

  defp runtime_snapshot(_), do: %{}

  defp safe_get_state(pid) do
    :sys.get_state(pid)
  catch
    :exit, _reason -> nil
  end

  defp maybe_update_machine_from_runtime(nil, _runtime), do: :ok
  defp maybe_update_machine_from_runtime(_machine_id, runtime) when runtime == %{}, do: :ok

  defp maybe_update_machine_from_runtime(machine_id, runtime) do
    existing = existing_machine(machine_id)

    snapshot = %MachineSnapshot{
      existing
      | current_state: Map.get(runtime, :current_state) || existing.current_state,
        health:
          infer_health(
            Map.get(runtime, :current_state) || existing.current_state,
            existing.health
          ),
        last_transition_at: Map.get(runtime, :last_transition_at) || existing.last_transition_at,
        facts: Map.get(runtime, :facts) || existing.facts,
        fields: Map.get(runtime, :fields) || existing.fields,
        outputs: Map.get(runtime, :outputs) || existing.outputs,
        connected?: true
    }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end
end
