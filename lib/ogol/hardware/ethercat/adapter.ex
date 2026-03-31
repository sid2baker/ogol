defmodule Ogol.Hardware.EtherCAT.Adapter do
  @moduledoc """
  EtherCAT-oriented hardware adapter over the external `:ethercat` project.
  """

  @behaviour Ogol.HardwareAdapter

  alias Ogol.HardwareConfig
  alias Ogol.HardwareConfig.EtherCAT, as: EtherCATConfig
  alias Ogol.Hardware.EtherCAT.Ref
  alias Ogol.Hardware.EtherCAT.RuntimeOwner
  alias Ogol.HMI.RuntimeNotifier

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
  def attach(_machine, server, refs) when is_list(refs) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case attach(nil, server, ref) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def attach(_machine, server, %Ref{slave: slave} = ref) do
    if Ref.observes_anything?(ref) do
      EtherCAT.subscribe(slave, server)
    else
      :ok
    end
  end

  def attach(_machine, _server, ref), do: {:error, {:invalid_ethercat_ref, ref}}

  @impl true
  def dispatch(_machine, refs, command, data, meta) when is_list(refs) do
    with {:ok, ref} <- select_dispatch_ref(refs, command) do
      dispatch(nil, ref, command, data, meta)
    end
  end

  def dispatch(_machine, %Ref{} = hardware_ref, command, data, _meta) do
    hardware_ref
    |> resolve_command(command, data)
    |> dispatch_operation(hardware_ref)
  end

  def dispatch(_machine, ref, _command, _data, _meta),
    do: {:error, {:invalid_ethercat_ref, ref}}

  @impl true
  def write_output(_machine, refs, output, value, meta) when is_list(refs) do
    with {:ok, ref} <- select_output_ref(refs, output) do
      write_output(nil, ref, output, value, meta)
    end
  end

  def write_output(_machine, %Ref{} = hardware_ref, output, value, _meta) do
    case EtherCAT.command(hardware_ref.slave, :set_output, %{endpoint: output, value: value}) do
      {:ok, _reference} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def write_output(_machine, ref, _output, _value, _meta),
    do: {:error, {:invalid_ethercat_ref, ref}}

  defp resolve_command(%Ref{} = ref, command, data) do
    case Map.get(ref.commands, command) do
      {:command, ethercat_command, args} when is_atom(ethercat_command) and is_map(args) ->
        {:ok, {:command, ethercat_command, Map.merge(args, data)}}

      nil ->
        {:ok, {:command, command, data}}

      other ->
        {:error, {:invalid_ethercat_command_mapping, command, other}}
    end
  end

  defp dispatch_operation({:ok, {:command, command, args}}, %Ref{} = ref) do
    case EtherCAT.command(ref.slave, command, args) do
      {:ok, _reference} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_operation({:error, reason}, _ref), do: {:error, reason}

  defp select_dispatch_ref([], command), do: {:error, {:unmapped_ethercat_command, command}}

  defp select_dispatch_ref(refs, command) do
    explicitly_mapped =
      Enum.filter(refs, fn
        %Ref{} = ref -> Ref.handles_command?(ref, command)
        _ -> false
      end)

    case explicitly_mapped do
      [ref] ->
        {:ok, ref}

      [] ->
        case refs do
          [%Ref{} = ref] -> {:ok, ref}
          _ -> {:error, {:unmapped_ethercat_command, command}}
        end

      _ ->
        {:error, {:ambiguous_ethercat_command_mapping, command}}
    end
  end

  defp select_output_ref([], output), do: {:error, {:unmapped_ethercat_output, output}}

  defp select_output_ref(refs, output) do
    mapped_refs =
      Enum.filter(refs, fn
        %Ref{} = ref -> Ref.handles_output?(ref, output)
        _ -> false
      end)

    case mapped_refs do
      [ref] ->
        {:ok, ref}

      [] ->
        {:error, {:unmapped_ethercat_output, output}}

      _ ->
        {:error, {:ambiguous_ethercat_output_mapping, output}}
    end
  end
end
