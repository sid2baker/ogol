defmodule Ogol.HMI.RuntimeIndex do
  @moduledoc false

  use GenServer

  @table __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  def put_machine(machine_id, attrs) when is_atom(machine_id) and is_map(attrs) do
    upsert({:machine, machine_id}, attrs)
  end

  def put_topology(topology_id, attrs) when is_atom(topology_id) and is_map(attrs) do
    upsert({:topology, topology_id}, attrs)
  end

  def put_hardware(endpoint_id, attrs) when is_map(attrs) do
    upsert({:hardware, endpoint_id}, attrs)
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  def find_machine_by_pid(pid) when is_pid(pid) do
    find_entry_by_pid(:machine, pid)
  end

  def find_topology_by_pid(pid) when is_pid(pid) do
    find_entry_by_pid(:topology, pid)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  defp upsert(key, attrs) do
    current = get(key) || %{}
    :ets.insert(@table, {key, Map.merge(current, attrs)})
    :ok
  end

  defp find_entry_by_pid(kind, pid) do
    @table
    |> :ets.tab2list()
    |> Enum.find_value(fn
      {{^kind, id}, %{pid: ^pid} = attrs} ->
        {id, attrs}

      {{^kind, id}, %{root_pid: ^pid} = attrs} ->
        {id, attrs}

      _other ->
        nil
    end)
  end
end
