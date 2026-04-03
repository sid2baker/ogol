defmodule Ogol.Hardware.EtherCAT.RuntimeOwner do
  @moduledoc false

  use GenServer

  alias EtherCAT.Backend
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias EtherCAT.Simulator.Slave, as: SimulatorSlave
  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATConfig
  alias Ogol.Hardware.EtherCAT.RuntimeHost
  alias Ogol.Hardware.EtherCAT.Session

  @timeout 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{runtime_pid: nil}, name: __MODULE__)
  end

  def start_simulator(spec) do
    GenServer.call(__MODULE__, {:start_simulator, spec}, @timeout)
  end

  def start_master(spec) do
    GenServer.call(__MODULE__, {:start_master, spec}, @timeout)
  end

  def stop_master do
    GenServer.call(__MODULE__, :stop_master, @timeout)
  end

  def stop_all do
    GenServer.call(__MODULE__, :stop_all, @timeout)
  end

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:start_simulator, spec}, _from, state) do
    result =
      with :ok <- stop_all_runtime(state.runtime_pid),
           {:ok, _simulator} <- Simulator.start(simulator_start_opts(spec)),
           {:ok, %SimulatorStatus{backend: backend}} <- normalized_simulator_status() do
        {:ok, %{backend: backend, port: backend_port(backend)}}
      else
        {:error, _reason} = error ->
          _ = stop_all_runtime(state.runtime_pid)
          error
      end

    {:reply, result, %{state | runtime_pid: nil}}
  end

  def handle_call({:start_master, spec}, _from, state) do
    result =
      with {:ok, runtime_pid} <- ensure_runtime_started(state.runtime_pid),
           :ok <- stop_master_runtime(),
           {:ok, runtime} <- Session.start_master(spec) do
        {:ok, runtime, runtime_pid}
      else
        {:error, _reason} = error -> error
      end

    case result do
      {:ok, %{backend: backend, port: port, state: lifecycle}, runtime_pid} ->
        {:reply, {:ok, %{backend: backend, port: port, state: lifecycle}},
         %{state | runtime_pid: runtime_pid}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop_master, _from, state) do
    result = stop_master_runtime()
    runtime_pid = stop_owned_runtime(state.runtime_pid)
    {:reply, result, %{state | runtime_pid: runtime_pid}}
  end

  def handle_call(:stop_all, _from, state) do
    result = stop_all_runtime(state.runtime_pid)
    {:reply, result, %{state | runtime_pid: nil}}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp stop_all_runtime(runtime_pid) do
    case stop_master_runtime() do
      :ok ->
        _ = Simulator.stop()
        _ = stop_owned_runtime(runtime_pid)
        :ok

      error ->
        error
    end
  end

  defp stop_master_runtime do
    Session.stop_master()
  end

  defp ensure_runtime_started(runtime_pid) when is_pid(runtime_pid) do
    if Process.alive?(runtime_pid) and is_pid(Process.whereis(EtherCAT.Master)) do
      {:ok, runtime_pid}
    else
      ensure_runtime_started(nil)
    end
  end

  defp ensure_runtime_started(_runtime_pid) do
    case Process.whereis(EtherCAT.Master) do
      pid when is_pid(pid) ->
        {:ok, nil}

      nil ->
        start_ethercat_runtime()
    end
  end

  defp start_ethercat_runtime do
    case RuntimeHost.start_link() do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_owned_runtime(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        Supervisor.stop(pid, :shutdown)
      catch
        :exit, _reason -> :ok
      end
    end

    nil
  end

  defp stop_owned_runtime(_pid), do: nil

  defp simulator_start_opts(%EtherCATConfig{} = spec) do
    {:ok, backend} = configured_backend(spec)

    [
      devices: Enum.map(spec.slaves, &SimulatorSlave.from_driver(&1.driver, name: &1.name)),
      backend: backend
    ]
  end

  defp configured_backend(%EtherCATConfig{} = spec) do
    case EtherCATConfig.transport_mode(spec) do
      :udp ->
        {:ok,
         %Backend.Udp{
           host: EtherCATConfig.simulator_ip(spec),
           bind_ip: EtherCATConfig.bind_ip(spec),
           port: 0
         }}

      :raw ->
        case EtherCATConfig.primary_interface(spec) do
          interface when is_binary(interface) and byte_size(interface) > 0 ->
            {:ok, %Backend.Raw{interface: interface}}

          _other ->
            {:error, :missing_primary_interface}
        end

      :redundant ->
        case {EtherCATConfig.primary_interface(spec), EtherCATConfig.secondary_interface(spec)} do
          {primary, secondary}
          when is_binary(primary) and byte_size(primary) > 0 and is_binary(secondary) and
                 byte_size(secondary) > 0 ->
            {:ok,
             %Backend.Redundant{
               primary: %Backend.Raw{interface: primary},
               secondary: %Backend.Raw{interface: secondary}
             }}

          {_primary, _secondary} ->
            {:error, :missing_secondary_interface}
        end
    end
  end

  defp normalized_simulator_status do
    with {:ok, %SimulatorStatus{backend: backend} = status} <- Simulator.status(),
         {:ok, normalized_backend} <- Backend.normalize(backend) do
      {:ok, %{status | backend: normalized_backend}}
    end
  end

  defp backend_port(%Backend.Udp{port: port}), do: port
  defp backend_port(_backend), do: nil
end
