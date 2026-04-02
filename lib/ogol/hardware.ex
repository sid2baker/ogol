defmodule Ogol.Hardware do
  @moduledoc false

  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATConfig
  alias Ogol.Hardware.EtherCAT.Binding, as: EtherCATBinding
  alias Ogol.Topology.Wiring

  @spec normalize_binding(module(), term()) :: term()
  def normalize_binding(Ogol.Hardware.EtherCAT.Adapter, binding) do
    case EtherCATBinding.normalize_runtime(binding) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> binding
    end
  end

  def normalize_binding(_adapter, binding), do: binding

  @spec adapter_for(term()) :: module()
  def adapter_for(binding) do
    case EtherCATBinding.normalize_runtime(binding) do
      {:ok, []} -> Ogol.Hardware.NoopAdapter
      {:ok, _normalized} -> Ogol.Hardware.EtherCAT.Adapter
      {:error, _reason} -> Ogol.Hardware.NoopAdapter
    end
  end

  @spec resolve_wiring(Wiring.t(), %{optional(String.t()) => term()}) ::
          {:ok, {module(), term()} | nil} | {:error, term()}
  def resolve_wiring(%Wiring{} = wiring, %{"ethercat" => %EtherCATConfig{} = spec}) do
    if Wiring.empty?(wiring) do
      {:ok, nil}
    else
      with {:ok, refs} <- resolve_ethercat_wiring(wiring, Map.get(spec, :slaves, [])) do
        {:ok, {Ogol.Hardware.EtherCAT.Adapter, refs}}
      end
    end
  end

  def resolve_wiring(%Wiring{} = wiring, hardware_configs) when is_map(hardware_configs) do
    if Wiring.empty?(wiring) do
      {:ok, nil}
    else
      {:error, {:missing_hardware_config, wiring}}
    end
  end

  defp resolve_ethercat_wiring(%Wiring{} = wiring, slaves) when is_list(slaves) do
    endpoint_index = build_ethercat_endpoint_index(slaves)

    with {:ok, output_groups} <- resolve_output_groups(wiring.outputs, endpoint_index),
         {:ok, fact_groups} <- resolve_fact_groups(wiring.facts, endpoint_index),
         {:ok, command_groups} <- resolve_command_groups(wiring.commands, endpoint_index) do
      refs =
        output_groups
        |> Map.merge(fact_groups, fn _slave, left, right -> Map.merge(left, right) end)
        |> Map.merge(command_groups, fn _slave, left, right -> Map.merge(left, right) end)
        |> Enum.map(fn {slave, attrs} ->
          %EtherCATBinding{
            slave: slave,
            outputs: Map.get(attrs, :outputs, %{}),
            facts: Map.get(attrs, :facts, %{}),
            commands: Map.get(attrs, :commands, %{}),
            event_name: wiring.event_name,
            meta: %{}
          }
        end)
        |> Enum.sort_by(& &1.slave)

      {:ok, refs}
    end
  end

  defp build_ethercat_endpoint_index(slaves) do
    Enum.reduce(slaves, %{}, fn
      %SlaveConfig{name: slave_name} = slave, acc ->
        aliases = Map.get(slave, :aliases, %{})

        Enum.reduce(aliases, acc, fn {_signal, endpoint}, nested_acc ->
          case endpoint do
            atom when is_atom(atom) -> Map.put_new(nested_acc, atom, slave_name)
            _other -> nested_acc
          end
        end)

      _slave, acc ->
        acc
    end)
  end

  defp resolve_output_groups(outputs, endpoint_index) do
    Enum.reduce_while(outputs, {:ok, %{}}, fn {port, endpoint}, {:ok, acc} ->
      case Map.fetch(endpoint_index, endpoint) do
        {:ok, slave} ->
          next_acc =
            update_in(
              acc,
              [Access.key(slave, %{}), Access.key(:outputs, %{})],
              &Map.put(&1, port, endpoint)
            )

          {:cont, {:ok, next_acc}}

        :error ->
          {:halt, {:error, {:unmapped_hardware_endpoint, endpoint, {:output, port}}}}
      end
    end)
  end

  defp resolve_fact_groups(facts, endpoint_index) do
    Enum.reduce_while(facts, {:ok, %{}}, fn {port, endpoint}, {:ok, acc} ->
      case Map.fetch(endpoint_index, endpoint) do
        {:ok, slave} ->
          next_acc =
            update_in(
              acc,
              [Access.key(slave, %{}), Access.key(:facts, %{})],
              &Map.put(&1, endpoint, port)
            )

          {:cont, {:ok, next_acc}}

        :error ->
          {:halt, {:error, {:unmapped_hardware_endpoint, endpoint, {:fact, port}}}}
      end
    end)
  end

  defp resolve_command_groups(commands, endpoint_index) do
    Enum.reduce_while(commands, {:ok, %{}}, fn {name, {:command, _command, args} = binding},
                                               {:ok, acc} ->
      with {:ok, endpoint} <- command_endpoint(name, args),
           {:ok, slave} <- fetch_endpoint_slave(endpoint_index, endpoint, {:command, name}) do
        next_acc =
          update_in(
            acc,
            [Access.key(slave, %{}), Access.key(:commands, %{})],
            &Map.put(&1, name, binding)
          )

        {:cont, {:ok, next_acc}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp command_endpoint(_name, %{} = args) do
    case Map.get(args, :endpoint) do
      endpoint when is_atom(endpoint) -> {:ok, endpoint}
      other -> {:error, {:invalid_command_endpoint, other}}
    end
  end

  defp fetch_endpoint_slave(endpoint_index, endpoint, context) do
    case Map.fetch(endpoint_index, endpoint) do
      {:ok, slave} -> {:ok, slave}
      :error -> {:error, {:unmapped_hardware_endpoint, endpoint, context}}
    end
  end
end
