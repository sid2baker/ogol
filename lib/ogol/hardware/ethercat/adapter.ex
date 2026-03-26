defmodule Ogol.Hardware.EtherCAT.Adapter do
  @moduledoc """
  EtherCAT-oriented hardware adapter over the external `:ethercat` project.
  """

  @behaviour Ogol.HardwareAdapter

  alias Ogol.Hardware.EtherCAT.Ref

  @impl true
  def attach(machine, server, refs) when is_list(refs) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case attach(machine, server, ref) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def attach(_machine, server, %Ref{mode: :simulator, slave: slave} = ref) do
    case simulator_subscription_target(ref) do
      nil -> :ok
      target -> EtherCAT.Simulator.subscribe(slave, target, server)
    end
  end

  def attach(_machine, server, %Ref{mode: :runtime, slave: slave} = ref) do
    if Ref.observes_anything?(ref) do
      EtherCAT.subscribe(slave, server)
    else
      :ok
    end
  end

  def attach(_machine, _server, ref), do: {:error, {:invalid_ethercat_ref, ref}}

  @impl true
  def dispatch(machine, refs, command, data, meta) when is_list(refs) do
    with {:ok, ref} <- select_dispatch_ref(refs, command) do
      dispatch(machine, ref, command, data, meta)
    end
  end

  def dispatch(_machine, %Ref{} = hardware_ref, command, data, meta) do
    hardware_ref
    |> resolve_command(command, data)
    |> dispatch_operation(hardware_ref, with_bus_meta(hardware_ref, meta))
  end

  def dispatch(_machine, ref, _command, _data, _meta),
    do: {:error, {:invalid_ethercat_ref, ref}}

  @impl true
  def write_output(machine, refs, output, value, meta) when is_list(refs) do
    with {:ok, ref} <- select_output_ref(refs, output) do
      write_output(machine, ref, output, value, meta)
    end
  end

  def write_output(_machine, %Ref{} = hardware_ref, output, value, meta) do
    signal = Map.get(hardware_ref.output_map, output, output)
    _meta = with_bus_meta(hardware_ref, meta)

    case hardware_ref.mode do
      :runtime ->
        case EtherCAT.command(hardware_ref.slave, :set_output, %{signal: signal, value: value}) do
          {:ok, _reference} -> :ok
          {:error, reason} -> {:error, reason}
        end

      :simulator ->
        EtherCAT.Simulator.set_value(hardware_ref.slave, signal, value)

      mode ->
        {:error, {:unsupported_ethercat_mode, mode}}
    end
  end

  def write_output(_machine, ref, _output, _value, _meta),
    do: {:error, {:invalid_ethercat_ref, ref}}

  defp resolve_command(%Ref{} = ref, command, data) do
    case Map.get(ref.command_map, command) do
      {:write_output, signal, value} ->
        {:ok, {:write_output, signal, value}}

      {:command, ethercat_command, args} when is_atom(ethercat_command) and is_map(args) ->
        {:ok, {:command, ethercat_command, Map.merge(args, data)}}

      nil when ref.mode == :runtime ->
        {:ok, {:command, command, data}}

      nil ->
        {:error, {:unmapped_ethercat_command, command}}

      other ->
        {:error, {:invalid_ethercat_command_mapping, command, other}}
    end
  end

  defp dispatch_operation(
         {:ok, {:write_output, signal, value}},
         %Ref{mode: :runtime} = ref,
         _meta
       ) do
    case EtherCAT.command(ref.slave, :set_output, %{signal: signal, value: value}) do
      {:ok, _reference} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_operation(
         {:ok, {:write_output, signal, value}},
         %Ref{mode: :simulator} = ref,
         _meta
       ) do
    EtherCAT.Simulator.set_value(ref.slave, signal, value)
  end

  defp dispatch_operation(
         {:ok, {:command, :set_output, %{signal: signal, value: value}}},
         %Ref{mode: :simulator} = ref,
         _meta
       ) do
    EtherCAT.Simulator.set_value(ref.slave, signal, value)
  end

  defp dispatch_operation({:ok, {:command, command, args}}, %Ref{mode: :runtime} = ref, _meta) do
    case EtherCAT.command(ref.slave, command, args) do
      {:ok, _reference} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch_operation(
         {:ok, {:command, command, _args}},
         %Ref{mode: :simulator},
         _meta
       ) do
    {:error, {:unsupported_simulator_command, command}}
  end

  defp dispatch_operation({:error, reason}, _ref, _meta), do: {:error, reason}

  defp with_bus_meta(%Ref{} = ref, meta) do
    ref.meta
    |> Map.merge(meta)
    |> Map.put_new(:bus, :ethercat)
  end

  defp select_dispatch_ref([], command), do: {:error, {:unmapped_ethercat_command, command}}

  defp select_dispatch_ref(refs, command) do
    explicitly_mapped =
      Enum.filter(refs, fn
        %Ref{command_map: command_map} -> Map.has_key?(command_map, command)
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
        %Ref{output_map: output_map} -> Map.has_key?(output_map, output)
        _ -> false
      end)

    case mapped_refs do
      [ref] ->
        {:ok, ref}

      [] ->
        case refs do
          [%Ref{} = ref] -> {:ok, ref}
          _ -> {:error, {:unmapped_ethercat_output, output}}
        end

      _ ->
        {:error, {:ambiguous_ethercat_output_mapping, output}}
    end
  end

  defp simulator_subscription_target(%Ref{} = ref) do
    case {Ref.observed_signals(ref), Ref.observes_events?(ref)} do
      {[], false} ->
        nil

      {[], true} ->
        :all

      {[signal], false} ->
        signal

      {_signals, _observe_events?} ->
        :all
    end
  end
end
