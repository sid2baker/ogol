defmodule Ogol.Hardware.EtherCAT.Session do
  @moduledoc false

  alias EtherCAT.Backend
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATConfig

  @await_timeout 2_000

  @spec start_master(EtherCATConfig.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_master(%EtherCATConfig{} = spec, opts \\ []) do
    await_timeout = Keyword.get(opts, :await_timeout, @await_timeout)

    with {:ok, backend} <- master_backend(spec),
         :ok <- EtherCAT.start(master_start_opts(spec, backend)),
         :ok <- EtherCAT.await_running(await_timeout),
         %Master.Status{} = status <- Master.status(),
         pid when is_pid(pid) <- Process.whereis(EtherCAT.Master) do
      {:ok,
       %{
         master_pid: pid,
         backend: backend,
         port: backend_port(backend),
         state: status.lifecycle
       }}
    else
      nil ->
        {:error, :master_not_running}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_master_status, other}}
    end
  end

  @spec stop_master() :: :ok | {:error, term()}
  def stop_master do
    case EtherCAT.stop() do
      :ok -> :ok
      {:error, :already_stopped} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec master_backend(EtherCATConfig.t()) :: {:ok, Backend.t()} | {:error, term()}
  def master_backend(%EtherCATConfig{} = spec) do
    case EtherCATConfig.transport_mode(spec) do
      :udp -> running_simulator_backend(spec)
      _other -> configured_backend(spec)
    end
  end

  @spec master_start_opts(EtherCATConfig.t(), Backend.t()) :: keyword()
  def master_start_opts(%EtherCATConfig{} = spec, backend) do
    [
      backend: backend,
      dc: nil,
      domains: EtherCATConfig.runtime_domains(spec),
      slaves: spec.slaves,
      scan_stable_ms: EtherCATConfig.scan_stable_ms(spec),
      scan_poll_ms: EtherCATConfig.scan_poll_ms(spec),
      frame_timeout_ms: EtherCATConfig.frame_timeout_ms(spec)
    ]
  end

  defp running_simulator_backend(%EtherCATConfig{} = spec) do
    case Simulator.status() do
      {:ok, %SimulatorStatus{lifecycle: :running, backend: %Backend.Udp{} = backend}} ->
        {:ok, %{backend | bind_ip: EtherCATConfig.bind_ip(spec)}}

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

  defp backend_port(%Backend.Udp{port: port}), do: port
  defp backend_port(_backend), do: nil
end
