defmodule Ogol.HMI.HardwareConfigStore do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.HardwareConfig

  @table :ogol_hmi_hardware_configs

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@table)
    :ok
  end

  def put_config(%HardwareConfig{} = config) do
    :ets.insert(@table, {config.id, config})
    :ok
  end

  def get_config(id) when is_binary(id) do
    case :ets.lookup(@table, id) do
      [{^id, %HardwareConfig{} = config}] -> config
      [] -> nil
    end
  end

  def list_configs do
    @table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(&{&1.protocol, &1.id})
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
