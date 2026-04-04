defmodule Ogol.Simulator.Config.EtherCAT do
  @moduledoc false

  alias EtherCAT.Simulator.Slave, as: SimulatorSlave
  alias Ogol.Hardware.EtherCAT, as: HardwareConfig
  alias Ogol.Hardware.EtherCAT.Driver.{EK1100, EL1809, EL2809}

  @artifact_id "ethercat"
  @default_host {127, 0, 0, 2}
  @default_port 0

  @type device_t :: %{
          name: atom(),
          driver: module()
        }

  @type signal_ref_t :: {atom(), atom()}

  @type connection_t :: %{
          source: signal_ref_t(),
          target: signal_ref_t()
        }

  @type backend_t ::
          {:udp, %{host: :inet.ip_address(), port: non_neg_integer()}}
          | {:raw, %{interface: String.t()}}
          | {:redundant,
             %{
               primary: {:raw, %{interface: String.t()}},
               secondary: {:raw, %{interface: String.t()}}
             }}

  @type topology_t :: :linear | :redundant

  @type t :: %{
          adapter: :ethercat,
          backend: backend_t(),
          topology: topology_t(),
          devices: [device_t()],
          connections: [connection_t()]
        }

  @spec artifact_id() :: String.t()
  def artifact_id, do: @artifact_id

  @spec default() :: t()
  def default do
    %{
      adapter: :ethercat,
      backend: {:udp, %{host: @default_host, port: @default_port}},
      topology: :linear,
      devices: default_devices(),
      connections: default_connections(default_devices())
    }
  end

  @spec from_hardware(HardwareConfig.t()) :: t()
  def from_hardware(%HardwareConfig{} = config) do
    devices = Enum.map(config.slaves, &device_from_slave/1)

    %{
      adapter: :ethercat,
      backend: backend_from_hardware(config),
      topology: topology_from_hardware(config),
      devices: devices,
      connections: default_connections(devices)
    }
  end

  @spec runtime_opts(t()) :: keyword()
  def runtime_opts(%{backend: backend, topology: topology, devices: devices}) do
    [
      devices: Enum.map(devices, &runtime_device/1),
      backend: backend,
      topology: topology
    ]
  end

  @spec connections(t()) :: [connection_t()]
  def connections(%{connections: connections}) when is_list(connections), do: connections
  def connections(_config), do: []

  @spec transport_mode(t()) :: :udp | :raw | :redundant
  def transport_mode(%{backend: {:udp, _opts}}), do: :udp
  def transport_mode(%{backend: {:raw, _opts}}), do: :raw
  def transport_mode(%{backend: {:redundant, _opts}}), do: :redundant

  @spec host(t()) :: :inet.ip_address() | nil
  def host(%{backend: {:udp, %{host: host}}}), do: host
  def host(_config), do: nil

  @spec port(t()) :: non_neg_integer() | nil
  def port(%{backend: {:udp, %{port: port}}}) when is_integer(port), do: port
  def port(_config), do: nil

  @spec primary_interface(t()) :: String.t() | nil
  def primary_interface(%{backend: {:raw, %{interface: interface}}}), do: interface

  def primary_interface(%{backend: {:redundant, %{primary: {:raw, %{interface: interface}}}}}),
    do: interface

  def primary_interface(_config), do: nil

  @spec secondary_interface(t()) :: String.t() | nil
  def secondary_interface(%{
        backend: {:redundant, %{secondary: {:raw, %{interface: interface}}}}
      }),
      do: interface

  def secondary_interface(_config), do: nil

  @spec device_names(t()) :: [atom()]
  def device_names(%{devices: devices}) do
    Enum.map(devices, & &1.name)
  end

  @spec default_host() :: :inet.ip_address()
  def default_host, do: @default_host

  @spec default_port() :: non_neg_integer()
  def default_port, do: @default_port

  defp default_devices do
    [
      %{name: :coupler, driver: EK1100},
      %{name: :inputs, driver: EL1809},
      %{name: :outputs, driver: EL2809}
    ]
  end

  defp default_connections(devices) when is_list(devices) do
    input_name = find_device_name(devices, EL1809)
    output_name = find_device_name(devices, EL2809)

    case {output_name, input_name} do
      {output_name, input_name} when is_atom(output_name) and is_atom(input_name) ->
        Enum.map(1..16, fn channel ->
          signal = String.to_atom("ch#{channel}")

          %{
            source: {output_name, signal},
            target: {input_name, signal}
          }
        end)

      _other ->
        []
    end
  end

  defp find_device_name(devices, driver) do
    case Enum.find(devices, &(&1.driver == driver)) do
      %{name: name} when is_atom(name) -> name
      _other -> nil
    end
  end

  defp device_from_slave(%{name: name, driver: driver}) when is_atom(name) and is_atom(driver) do
    %{name: name, driver: driver}
  end

  defp runtime_device(%{name: name, driver: driver}) do
    SimulatorSlave.from_driver(driver, name: name)
  end

  defp backend_from_hardware(%HardwareConfig{} = config) do
    case HardwareConfig.transport_mode(config) do
      :udp ->
        {:udp, %{host: @default_host, port: @default_port}}

      :raw ->
        {:raw, %{interface: HardwareConfig.primary_interface(config) || ""}}

      :redundant ->
        {:redundant,
         %{
           primary: {:raw, %{interface: HardwareConfig.primary_interface(config) || ""}},
           secondary: {:raw, %{interface: HardwareConfig.secondary_interface(config) || ""}}
         }}
    end
  end

  defp topology_from_hardware(%HardwareConfig{} = config) do
    case HardwareConfig.transport_mode(config) do
      :redundant -> :redundant
      _other -> :linear
    end
  end
end
