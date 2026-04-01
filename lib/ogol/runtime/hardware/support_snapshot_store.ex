defmodule Ogol.Runtime.Hardware.SupportSnapshotStore do
  @moduledoc false

  use GenServer

  alias Ogol.Runtime.Hardware.SupportSnapshot, as: HardwareSupportSnapshot

  @table :ogol_hmi_hardware_support_snapshots

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  def put_snapshot(%HardwareSupportSnapshot{} = snapshot) do
    :ets.insert(@table, {snapshot.id, snapshot})
    :ok
  end

  def get_snapshot(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, %HardwareSupportSnapshot{} = snapshot}] -> snapshot
      [] -> nil
    end
  end

  def list_snapshots do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.captured_at, :desc)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
