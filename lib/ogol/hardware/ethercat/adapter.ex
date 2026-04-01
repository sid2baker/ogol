defmodule Ogol.Hardware.EtherCAT.Adapter do
  @moduledoc """
  EtherCAT-oriented hardware adapter over the external `:ethercat` project.
  """

  @behaviour Ogol.Hardware.Adapter

  alias Ogol.Hardware.Config, as: HardwareConfig
  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATConfig
  alias Ogol.Hardware.EtherCAT.Binding
  alias Ogol.Hardware.EtherCAT.RuntimeOwner
  alias Ogol.Runtime.Notifier, as: RuntimeNotifier

  @type activation_result :: %{
          config: HardwareConfig.t(),
          master: map(),
          simulator: map() | nil
        }

  @spec ensure_ready(HardwareConfig.t()) :: {:ok, activation_result()} | {:error, term()}
  def ensure_ready(%HardwareConfig{protocol: :ethercat, spec: %EtherCATConfig{} = spec} = config) do
    simulator_result =
      case EtherCATConfig.transport_mode(spec) do
        :udp -> start_simulator(config)
        _other -> with :ok <- stop(), do: {:ok, nil}
      end

    with {:ok, simulator} <- simulator_result,
         {:ok, master} <- start_master(config) do
      RuntimeNotifier.emit(:hardware_session_control_applied,
        source: __MODULE__,
        payload: %{
          protocol: :ethercat,
          action: :activate_runtime,
          config_id: config.id,
          label: config.label
        },
        meta: %{bus: :ethercat, config_id: config.id}
      )

      {:ok, %{config: config, simulator: simulator, master: master}}
    else
      {:error, reason} = error ->
        _ = stop()

        RuntimeNotifier.emit(:hardware_session_control_failed,
          source: __MODULE__,
          payload: %{
            protocol: :ethercat,
            action: :activate_runtime,
            config_id: config.id,
            reason: reason
          },
          meta: %{bus: :ethercat, config_id: config.id}
        )

        error
    end
  end

  def ensure_ready(%HardwareConfig{} = config),
    do: {:error, {:unsupported_hardware_protocol, config.protocol}}

  @spec start_simulator(HardwareConfig.t()) :: {:ok, map()} | {:error, term()}
  def start_simulator(
        %HardwareConfig{protocol: :ethercat, spec: %EtherCATConfig{} = spec} = config
      ) do
    with {:ok, %{port: port}} <- RuntimeOwner.start_simulator(spec) do
      RuntimeNotifier.emit(:hardware_simulation_started,
        source: __MODULE__,
        payload: %{
          protocol: :ethercat,
          config_id: config.id,
          label: config.label,
          slave_count: length(spec.slaves),
          config: config
        },
        meta: %{bus: :ethercat, config_id: config.id}
      )

      {:ok,
       %{
         config_id: config.id,
         port: port,
         slaves: Enum.map(spec.slaves, & &1.name)
       }}
    else
      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_simulation_failed,
          source: __MODULE__,
          payload: %{protocol: :ethercat, config_id: config.id, reason: reason},
          meta: %{bus: :ethercat, config_id: config.id}
        )

        error
    end
  end

  def start_simulator(%HardwareConfig{} = config),
    do: {:error, {:unsupported_hardware_protocol, config.protocol}}

  @spec start_master(HardwareConfig.t()) :: {:ok, map()} | {:error, term()}
  def start_master(%HardwareConfig{protocol: :ethercat, spec: %EtherCATConfig{} = spec} = config) do
    with {:ok, %{state: state}} <- RuntimeOwner.start_master(spec) do
      RuntimeNotifier.emit(:hardware_session_control_applied,
        source: __MODULE__,
        payload: %{
          protocol: :ethercat,
          action: :start_master,
          config_id: config.id,
          label: config.label
        },
        meta: %{bus: :ethercat, config_id: config.id}
      )

      {:ok,
       %{
         config: config,
         config_id: config.id,
         state: state,
         slaves: Enum.map(spec.slaves, & &1.name)
       }}
    else
      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_session_control_failed,
          source: __MODULE__,
          payload: %{
            protocol: :ethercat,
            action: :start_master,
            config_id: config.id,
            label: config.label,
            reason: reason
          },
          meta: %{bus: :ethercat, config_id: config.id}
        )

        error
    end
  end

  def start_master(%HardwareConfig{} = config),
    do: {:error, {:unsupported_hardware_protocol, config.protocol}}

  @spec stop() :: :ok | {:error, term()}
  def stop do
    RuntimeOwner.stop_all()
  end

  @impl true
  def attach(_machine, server, bindings) when is_list(bindings) do
    Enum.reduce_while(bindings, :ok, fn binding, :ok ->
      case attach(nil, server, binding) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def attach(_machine, server, %Binding{slave: slave} = binding) do
    if Binding.observes_anything?(binding) do
      EtherCAT.subscribe(slave, server)
    else
      :ok
    end
  end

  def attach(_machine, _server, binding), do: {:error, {:invalid_ethercat_binding, binding}}

  @impl true
  def dispatch(_machine, bindings, command, data, meta) when is_list(bindings) do
    with {:ok, binding} <- select_dispatch_binding(bindings, command) do
      dispatch(nil, binding, command, data, meta)
    end
  end

  def dispatch(_machine, %Binding{} = binding, command, data, _meta) do
    binding
    |> resolve_command(command, data)
    |> dispatch_operation(binding)
  end

  def dispatch(_machine, binding, _command, _data, _meta),
    do: {:error, {:invalid_ethercat_binding, binding}}

  @impl true
  def write_output(_machine, bindings, output, value, meta) when is_list(bindings) do
    with {:ok, binding} <- select_output_binding(bindings, output) do
      write_output(nil, binding, output, value, meta)
    end
  end

  def write_output(_machine, %Binding{} = binding, output, value, _meta) do
    case Binding.output_endpoint(binding, output) do
      endpoint when is_atom(endpoint) ->
        case EtherCAT.command(binding.slave, :set_output, %{endpoint: endpoint, value: value}) do
          {:ok, _reference} -> :ok
          {:error, reason} -> {:error, reason}
        end

      nil ->
        {:error, {:unmapped_ethercat_output, output}}
    end
  end

  def write_output(_machine, binding, _output, _value, _meta),
    do: {:error, {:invalid_ethercat_binding, binding}}

  defp resolve_command(%Binding{} = binding, command, data) do
    case Map.get(binding.commands, command) do
      {:command, ethercat_command, args} when is_atom(ethercat_command) and is_map(args) ->
        {:ok, {:command, ethercat_command, Map.merge(args, data)}}

      nil ->
        {:ok, {:command, command, data}}

      other ->
        {:error, {:invalid_ethercat_command_mapping, command, other}}
    end
  end

  defp dispatch_operation({:ok, {:command, command, args}}, %Binding{} = binding) do
    case EtherCAT.command(binding.slave, command, args) do
      {:ok, _reference} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_operation({:error, reason}, _binding), do: {:error, reason}

  defp select_dispatch_binding([], command), do: {:error, {:unmapped_ethercat_command, command}}

  defp select_dispatch_binding(bindings, command) do
    explicitly_mapped =
      Enum.filter(bindings, fn
        %Binding{} = binding -> Binding.handles_command?(binding, command)
        _ -> false
      end)

    case explicitly_mapped do
      [binding] ->
        {:ok, binding}

      [] ->
        case bindings do
          [%Binding{} = binding] -> {:ok, binding}
          _ -> {:error, {:unmapped_ethercat_command, command}}
        end

      _ ->
        {:error, {:ambiguous_ethercat_command_mapping, command}}
    end
  end

  defp select_output_binding([], output), do: {:error, {:unmapped_ethercat_output, output}}

  defp select_output_binding(bindings, output) do
    mapped_refs =
      Enum.filter(bindings, fn
        %Binding{} = binding -> Binding.handles_output?(binding, output)
        _ -> false
      end)

    case mapped_refs do
      [binding] ->
        {:ok, binding}

      [] ->
        {:error, {:unmapped_ethercat_output, output}}

      _ ->
        {:error, {:ambiguous_ethercat_output_mapping, output}}
    end
  end
end
