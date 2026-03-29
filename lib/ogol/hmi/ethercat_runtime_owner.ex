defmodule Ogol.HMI.EthercatRuntimeOwner do
  @moduledoc false

  use GenServer

  alias EtherCAT.Backend
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias EtherCAT.Simulator.Slave, as: SimulatorSlave

  @timeout 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
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
      with :ok <- stop_all_runtime(),
           {:ok, _simulator} <- Simulator.start(simulator_start_opts(spec)),
           {:ok, %SimulatorStatus{backend: backend}} <- normalized_simulator_status() do
        {:ok, %{backend: backend, port: backend_port(backend)}}
      else
        {:error, _reason} = error ->
          _ = stop_all_runtime()
          error
      end

    {:reply, result, state}
  end

  def handle_call({:start_master, spec}, _from, state) do
    result =
      with {:ok, backend} <- master_backend(spec),
           :ok <- stop_master_runtime(),
           :ok <- EtherCAT.start(master_start_opts(spec, backend)),
           :ok <- EtherCAT.await_running(2_000),
           %Master.Status{} = status <- Master.status() do
        {:ok, %{backend: backend, port: backend_port(backend), state: status.lifecycle}}
      else
        {:error, _reason} = error -> error
      end

    {:reply, result, state}
  end

  def handle_call(:stop_master, _from, state) do
    {:reply, stop_master_runtime(), state}
  end

  def handle_call(:stop_all, _from, state) do
    {:reply, stop_all_runtime(), state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

  defp stop_all_runtime do
    case stop_master_runtime() do
      :ok ->
        _ = Simulator.stop()
        :ok

      error ->
        error
    end
  end

  defp stop_master_runtime do
    case EtherCAT.stop() do
      :ok -> :ok
      {:error, :already_stopped} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp running_simulator_backend(spec) do
    case Simulator.status() do
      {:ok, %SimulatorStatus{lifecycle: :running, backend: %Backend.Udp{} = backend}} ->
        {:ok, %{backend | bind_ip: spec.bind_ip}}

      {:ok, %SimulatorStatus{lifecycle: :running, backend: %Backend.Raw{} = backend}} ->
        {:ok, backend}

      {:ok, %SimulatorStatus{lifecycle: :running, backend: %Backend.Redundant{} = backend}} ->
        {:ok, backend}

      {:ok, %SimulatorStatus{lifecycle: :running, backend: nil}} ->
        {:error, :simulator_backend_unknown}

      {:ok, %SimulatorStatus{lifecycle: :stopped}} ->
        {:error, :simulator_not_running}

      {:error, _reason} ->
        {:error, :simulator_not_running}
    end
  end

  defp simulator_start_opts(spec) do
    {:ok, backend} = configured_backend(spec)

    [
      devices: Enum.map(spec.slaves, &SimulatorSlave.from_driver(&1.driver, name: &1.name)),
      backend: backend
    ]
  end

  defp master_backend(%{transport: :udp} = spec), do: running_simulator_backend(spec)
  defp master_backend(spec), do: configured_backend(spec)

  defp configured_backend(%{transport: :udp} = spec) do
    {:ok, %Backend.Udp{host: spec.simulator_ip, bind_ip: spec.bind_ip, port: 0}}
  end

  defp configured_backend(%{transport: :raw, primary_interface: interface})
       when is_binary(interface) and byte_size(interface) > 0 do
    {:ok, %Backend.Raw{interface: interface}}
  end

  defp configured_backend(%{
         transport: :redundant,
         primary_interface: primary,
         secondary_interface: secondary
       })
       when is_binary(primary) and byte_size(primary) > 0 and is_binary(secondary) and
              byte_size(secondary) > 0 do
    {:ok,
     %Backend.Redundant{
       primary: %Backend.Raw{interface: primary},
       secondary: %Backend.Raw{interface: secondary}
     }}
  end

  defp configured_backend(%{transport: :raw}), do: {:error, :missing_primary_interface}
  defp configured_backend(%{transport: :redundant}), do: {:error, :missing_secondary_interface}

  defp normalized_simulator_status do
    with {:ok, %SimulatorStatus{backend: backend} = status} <- Simulator.status(),
         {:ok, normalized_backend} <- Backend.normalize(backend) do
      {:ok, %{status | backend: normalized_backend}}
    end
  end

  defp master_start_opts(spec, backend) do
    [
      backend: backend,
      dc: nil,
      domains: spec.domains,
      slaves: spec.slaves,
      scan_stable_ms: spec.scan_stable_ms,
      scan_poll_ms: spec.scan_poll_ms,
      frame_timeout_ms: spec.frame_timeout_ms
    ]
  end

  defp backend_port(%Backend.Udp{port: port}), do: port
  defp backend_port(_backend), do: nil
end
