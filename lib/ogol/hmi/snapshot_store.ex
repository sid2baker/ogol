defmodule Ogol.HMI.SnapshotStore do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.{HardwareSnapshot, MachineSnapshot, TopologySnapshot}

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
