defmodule Ogol.Hardware.EtherCAT.TopologySession do
  @moduledoc false

  use GenServer

  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATConfig
  alias Ogol.Hardware.EtherCAT.Session

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Keyword.fetch!(opts, :config)

    with %EtherCATConfig{} = config <- config,
         {:ok, runtime} <- Session.start_master(config) do
      {:ok,
       %{
         config: config,
         master_pid: runtime.master_pid,
         master_ref: Process.monitor(runtime.master_pid)
       }}
    else
      {:error, reason} ->
        {:stop, {:hardware_activation_failed, reason}}

      _other ->
        {:stop, {:hardware_activation_failed, :invalid_ethercat_config}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{master_ref: ref} = state) do
    {:stop, {:hardware_runtime_down, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    _ = Session.stop_master()
    :ok
  end
end
