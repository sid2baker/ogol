defmodule Ogol.Topology.Plan do
  @moduledoc false

  alias Ogol.Topology
  alias Ogol.Topology.Model
  alias Ogol.Topology.Registry

  @type t :: %{
          topology_scope: atom(),
          machine_specs: [Supervisor.child_spec()],
          required_hardware: %{optional(String.t()) => module()},
          hardware_children: [Supervisor.child_spec()]
        }

  @spec build(Model.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Model{} = topology, opts \\ []) do
    topology_scope = Topology.scope(topology.module)
    signal_sink = Keyword.get(opts, :signal_sink)
    machine_overrides = Keyword.get(opts, :machine_opts, %{})
    hardware = Keyword.get(opts, :hardware, %{})

    with {:ok, machine_specs, required_hardware} <-
           build_machine_specs(
             topology,
             signal_sink,
             machine_overrides,
             hardware,
             topology_scope
           ),
         {:ok, hardware_children} <- hardware_child_specs(required_hardware) do
      {:ok,
       %{
         topology_scope: topology_scope,
         machine_specs: machine_specs,
         required_hardware: required_hardware,
         hardware_children: hardware_children
       }}
    end
  end

  defp build_machine_specs(
         %Model{} = topology,
         signal_sink,
         machine_overrides,
         hardware,
         topology_scope
       ) do
    Enum.reduce_while(topology.machines, {:ok, [], %{}}, fn spec, {:ok, acc, required_hardware} ->
      override_opts = Map.get(machine_overrides, spec.name, [])

      case resolve_machine_wiring_opts(Map.get(spec, :wiring), hardware) do
        {:ok, wiring_opts, required_configs} ->
          machine_opts =
            spec
            |> Map.get(:opts, [])
            |> Keyword.merge(override_opts)
            |> Keyword.merge(wiring_opts)
            |> Keyword.put(:machine_id, spec.name)
            |> Keyword.put(:topology_id, topology_scope)
            |> Keyword.put(:name, Registry.via(spec.name))
            |> Keyword.put(:signal_sink, signal_sink)

          child_spec =
            Supervisor.child_spec({spec.module, machine_opts},
              id: {:ogol_machine, spec.name},
              restart: Map.get(spec, :restart, :permanent)
            )

          {:cont, {:ok, acc ++ [child_spec], Map.merge(required_hardware, required_configs)}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_topology_wiring, spec.name, reason}}}
      end
    end)
  end

  defp resolve_machine_wiring_opts(nil, _hardware), do: {:ok, [], %{}}

  defp resolve_machine_wiring_opts(wiring, _hardware)
       when is_struct(wiring, Ogol.Topology.Wiring) and wiring.facts == %{} and
              wiring.outputs == %{} and wiring.commands == %{} and is_nil(wiring.event_name) do
    {:ok, [], %{}}
  end

  defp resolve_machine_wiring_opts(wiring, hardware) when hardware == %{},
    do: {:error, {:missing_hardware, wiring}}

  defp resolve_machine_wiring_opts(%Ogol.Topology.Wiring{} = wiring, hardware) do
    with {:ok, {hardware_id, module}} <- bound_hardware_module(hardware),
         {:ok, binding} <- module.bind(wiring) do
      case binding do
        nil -> {:ok, [], %{}}
        _other -> {:ok, [io_adapter: module, io_binding: binding], %{hardware_id => module}}
      end
    end
  end

  defp bound_hardware_module(hardware) when is_map(hardware) do
    hardware
    |> Enum.filter(fn {_id, module} -> is_atom(module) end)
    |> case do
      [{hardware_id, module}] ->
        {:ok, {hardware_id, module}}

      [] ->
        {:error, :no_hardware_available}

      _many ->
        {:error, :ambiguous_hardware_binding}
    end
  end

  defp hardware_child_specs(required_hardware) when required_hardware == %{}, do: {:ok, []}

  defp hardware_child_specs(required_hardware) when is_map(required_hardware) do
    required_hardware
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {hardware_id, module}, {:ok, acc} ->
      case hardware_child_specs(hardware_id, module) do
        {:ok, child_specs} ->
          {:cont, {:ok, acc ++ child_specs}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp hardware_child_specs(_hardware_id, module) when is_atom(module) do
    module.child_specs([])
  end

  defp hardware_child_specs(hardware_id, _module),
    do: {:error, {:unsupported_hardware, hardware_id}}
end
