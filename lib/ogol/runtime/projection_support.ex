defmodule Ogol.Runtime.Bus do
  @moduledoc false

  @pubsub Ogol.Runtime.PubSub

  def overview_topic, do: "overview"
  def machine_topic(machine_id), do: "machine:#{machine_id}"
  def topology_topic(topology_id), do: "topology:#{topology_id}"
  def hardware_topic(bus, endpoint_id), do: "hardware:#{bus}:#{endpoint_id}"
  def events_topic, do: "events"
  def workspace_topic, do: "studio:workspace"

  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)
  def broadcast(topic, message), do: Phoenix.PubSub.broadcast(@pubsub, topic, message)
end

defmodule Ogol.Runtime.Notification do
  @moduledoc """
  Stable runtime notification envelope consumed by the HMI projection layer.
  """

  @type type ::
          :machine_started
          | :machine_stopped
          | :machine_down
          | :state_entered
          | :operator_skill_invoked
          | :operator_skill_failed
          | :signal_emitted
          | :command_dispatched
          | :command_failed
          | :safety_violation
          | :adapter_feedback
          | :adapter_status_changed
          | :hardwareuration_applied
          | :hardwareuration_failed
          | :hardware_session_control_applied
          | :hardware_session_control_failed
          | :hardware_saved
          | :hardware_simulation_started
          | :hardware_simulation_failed
          | :topology_ready

  @type t :: %__MODULE__{
          type: type(),
          machine_id: atom() | nil,
          topology_id: atom() | nil,
          source: term(),
          occurred_at: integer(),
          payload: map(),
          meta: map()
        }

  @enforce_keys [:type, :occurred_at]
  defstruct [:type, :machine_id, :topology_id, :source, :occurred_at, payload: %{}, meta: %{}]

  @spec new(type(), keyword()) :: t()
  def new(type, opts \\ []) when is_atom(type) and is_list(opts) do
    %__MODULE__{
      type: type,
      machine_id: Keyword.get(opts, :machine_id),
      topology_id: Keyword.get(opts, :topology_id),
      source: Keyword.get(opts, :source),
      occurred_at: Keyword.get(opts, :occurred_at, System.system_time(:millisecond)),
      payload: Keyword.get(opts, :payload, %{}),
      meta: Keyword.get(opts, :meta, %{})
    }
  end
end

defmodule Ogol.Runtime.Notifier do
  @moduledoc false

  alias Ogol.Runtime.Notification

  def emit(type, opts \\ []) when is_atom(type) and is_list(opts) do
    Notification.new(type, opts)
    |> Ogol.Runtime.Projector.project()

    :ok
  end
end

defmodule Ogol.Runtime.HardwareSnapshot do
  @moduledoc false

  @enforce_keys [:bus, :endpoint_id, :connected?]
  defstruct [
    :bus,
    :endpoint_id,
    :connected?,
    :last_feedback_at,
    observed_signals: %{},
    driven_outputs: %{},
    status: %{},
    faults: [],
    meta: %{}
  ]
end

defmodule Ogol.Runtime.MachineSnapshot do
  @moduledoc false

  @type health ::
          :healthy
          | :running
          | :waiting
          | :stopped
          | :faulted
          | :crashed
          | :recovering
          | :stale
          | :disconnected

  @type t :: %__MODULE__{
          machine_id: atom(),
          module: module() | nil,
          current_state: atom() | nil,
          health: health(),
          last_signal: atom() | nil,
          last_transition_at: integer() | nil,
          restart_count: non_neg_integer(),
          connected?: boolean(),
          facts: map(),
          fields: map(),
          outputs: map(),
          alarms: [map()],
          faults: [map()],
          dependencies: [map()],
          adapter_status: map(),
          meta: map()
        }

  @enforce_keys [:machine_id, :health]
  defstruct [
    :machine_id,
    :module,
    :current_state,
    :health,
    :last_signal,
    :last_transition_at,
    restart_count: 0,
    connected?: false,
    facts: %{},
    fields: %{},
    outputs: %{},
    alarms: [],
    faults: [],
    dependencies: [],
    adapter_status: %{},
    meta: %{}
  ]
end

defmodule Ogol.Runtime.TopologySnapshot do
  @moduledoc false

  @enforce_keys [:topology_id, :health]
  defstruct [
    :topology_id,
    :health,
    :connected?,
    meta: %{}
  ]
end

defmodule Ogol.Runtime.EventLog do
  @moduledoc false

  use GenServer

  @default_max_events 500

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def append(notification) do
    GenServer.cast(__MODULE__, {:append, notification})
  end

  def recent(limit \\ 100) do
    GenServer.call(__MODULE__, {:recent, limit})
  end

  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(opts) do
    {:ok, %{events: [], max_events: Keyword.get(opts, :max_events, @default_max_events)}}
  end

  @impl true
  def handle_cast({:append, notification}, state) do
    events =
      [notification | state.events]
      |> Enum.take(state.max_events)

    {:noreply, %{state | events: events}}
  end

  @impl true
  def handle_call({:recent, limit}, _from, state) do
    {:reply, state.events |> Enum.take(limit) |> Enum.reverse(), state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | events: []}}
  end
end

defmodule Ogol.Runtime.SnapshotStore do
  @moduledoc false

  use GenServer

  alias Ogol.Runtime.{HardwareSnapshot, MachineSnapshot, TopologySnapshot}

  @machine_table :ogol_hmi_machine_snapshots
  @topology_table :ogol_hmi_topology_snapshots
  @hardware_table :ogol_hmi_hardware_snapshots

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@machine_table)
    :ets.delete_all_objects(@topology_table)
    :ets.delete_all_objects(@hardware_table)
    :ok
  end

  def put_machine(%MachineSnapshot{} = snapshot) do
    :ets.insert(@machine_table, {snapshot.machine_id, snapshot})
    :ok
  end

  def get_machine(machine_id) do
    lookup(@machine_table, machine_id)
  end

  def list_machines do
    @machine_table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(&to_string(&1.machine_id))
  end

  def put_topology(%TopologySnapshot{} = snapshot) do
    :ets.insert(@topology_table, {snapshot.topology_id, snapshot})
    :ok
  end

  def get_topology(topology_id) do
    lookup(@topology_table, topology_id)
  end

  def list_topologies do
    @topology_table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(&to_string(&1.topology_id))
  end

  def put_hardware(%HardwareSnapshot{} = snapshot) do
    :ets.insert(@hardware_table, {{snapshot.bus, snapshot.endpoint_id}, snapshot})
    :ok
  end

  def get_hardware(bus, endpoint_id) do
    lookup(@hardware_table, {bus, endpoint_id})
  end

  def list_hardware do
    @hardware_table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(fn snapshot -> {to_string(snapshot.bus), to_string(snapshot.endpoint_id)} end)
  end

  @impl true
  def init(_opts) do
    :ets.new(@machine_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@topology_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@hardware_table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end
end

defmodule Ogol.Runtime.Projector do
  @moduledoc false

  use GenServer

  alias Ogol.Runtime.{
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
    topology_id = notification.topology_id || existing.meta[:topology_id]

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
        meta:
          existing.meta
          |> Map.put(:topology_id, topology_id)
          |> Map.put(:last_started_at, notification.occurred_at)
      }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :state_entered} = notification) do
    existing = existing_machine(notification.machine_id)
    runtime = runtime_snapshot(notification.meta[:pid])
    topology_id = notification.topology_id || existing.meta[:topology_id]

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
        outputs: Map.get(runtime, :outputs) || existing.outputs,
        meta: Map.put(existing.meta, :topology_id, topology_id)
    }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :signal_emitted} = notification) do
    existing = existing_machine(notification.machine_id)
    runtime = runtime_snapshot(notification.meta[:pid])
    topology_id = notification.topology_id || existing.meta[:topology_id]

    snapshot = %MachineSnapshot{
      existing
      | last_signal: notification.payload[:name],
        connected?: true,
        facts: Map.get(runtime, :facts) || existing.facts,
        fields: Map.get(runtime, :fields) || existing.fields,
        outputs: Map.get(runtime, :outputs) || existing.outputs,
        meta: Map.put(existing.meta, :topology_id, topology_id)
    }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :machine_stopped} = notification) do
    existing = existing_machine(notification.machine_id)
    topology_id = notification.topology_id || existing.meta[:topology_id]

    snapshot =
      %MachineSnapshot{
        existing
        | health: :stopped,
          connected?: false,
          meta:
            existing.meta
            |> Map.put(:topology_id, topology_id)
            |> Map.put(:stop_reason, notification.payload[:reason])
      }

    SnapshotStore.put_machine(snapshot)
    broadcast_machine(snapshot)
  end

  defp apply_notification(%Notification{type: :machine_down} = notification) do
    existing = existing_machine(notification.machine_id)
    topology_id = notification.topology_id || existing.meta[:topology_id]

    snapshot =
      %MachineSnapshot{
        existing
        | health: :crashed,
          connected?: false,
          restart_count: existing.restart_count + 1,
          faults: [
            %{reason: notification.payload[:reason], at: notification.occurred_at}
            | existing.faults
          ],
          meta: Map.put(existing.meta, :topology_id, topology_id)
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
    existing = existing_topology(notification.topology_id)

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

  defp existing_topology(topology_id) do
    case SnapshotStore.get_topology(topology_id) do
      %TopologySnapshot{} = snapshot ->
        snapshot

      nil ->
        %TopologySnapshot{
          topology_id: topology_id,
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

  defp infer_health(state, _current) when state in [:running], do: :running
  defp infer_health(state, _current) when state in [:idle, :waiting], do: :waiting
  defp infer_health(state, _current) when state in [:fault, :faulted], do: :faulted
  defp infer_health(_state, current) when current in [:crashed, :faulted], do: current
  defp infer_health(_state, _current), do: :healthy

  defp runtime_snapshot(pid) when is_pid(pid) do
    case safe_get_state(pid) do
      {state_name, %Ogol.Runtime.Data{} = data} ->
        %{
          current_state: state_name,
          facts: Ogol.Runtime.Observation.resolved_facts(data),
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
