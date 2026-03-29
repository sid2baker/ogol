defmodule Ogol.Hardware.EtherCAT.Adapter do
  @moduledoc """
  EtherCAT-oriented hardware adapter over the external `:ethercat` project.
  """

  @behaviour Ogol.HardwareAdapter

  alias Ogol.Hardware.EtherCAT.Ref

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
