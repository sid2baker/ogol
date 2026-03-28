defmodule Ogol.HMI.HardwareSupportSnapshotStore do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.HardwareSupportSnapshot

  @table :ogol_hmi_hardware_support_snapshots

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    ensure_started()

    if table_ready?() do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  def put_snapshot(%HardwareSupportSnapshot{} = snapshot) do
    ensure_started()
    :ets.insert(@table, {snapshot.id, snapshot})
    :ok
  end

  def get_snapshot(id) when is_binary(id) do
    ensure_started()

    if table_ready?() do
      case :ets.lookup(@table, id) do
        [{^id, %HardwareSupportSnapshot{} = snapshot}] -> snapshot
        [] -> nil
      end
    else
      nil
    end
  end

  def list_snapshots do
    ensure_started()

    if table_ready?() do
      @table
      |> :ets.tab2list()
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort_by(& &1.captured_at, :desc)
    else
      []
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil ->
        case start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(__MODULE__)}: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp table_ready? do
    :ets.whereis(@table) != :undefined
  end
end
