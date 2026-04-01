defmodule Ogol.Topology.Runtime do
  @moduledoc false

  use GenServer

  alias Ogol.Topology.Model

  defstruct [:topology_id, :supervisor]

  def start_link(%Model{} = topology, opts \\ []) do
    GenServer.start_link(__MODULE__, {topology, opts}, name: Keyword.get(opts, :name))
  end

  def start(%Model{} = topology, opts \\ []) do
    GenServer.start(__MODULE__, {topology, opts}, name: Keyword.get(opts, :name))
  end

  def machine_pid(topology, name) when is_pid(topology) and is_atom(name) do
    GenServer.call(topology, {:machine_pid, name})
  end

  @impl true
  def init({%Model{} = topology, opts}) do
    with :ok <-
           Ogol.Topology.Registry.claim_topology(%{
             module: topology.module,
             topology_id: topology.topology_id
           }),
         {:ok, machine_specs} <- build_machine_specs(topology, opts),
         {:ok, supervisor} <-
           Supervisor.start_link(machine_specs, strategy: topology.strategy) do
      Ogol.Runtime.Notifier.emit(:topology_ready,
        machine_id: topology.topology_id,
        topology_id: topology.topology_id,
        source: __MODULE__,
        payload: %{topology_id: topology.topology_id},
        meta: %{pid: self(), supervisor: supervisor}
      )

      {:ok, %__MODULE__{topology_id: topology.topology_id, supervisor: supervisor}}
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:machine_pid, name}, _from, state) do
    {:reply, Ogol.Topology.Registry.whereis(name), state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_if_alive(state.supervisor)
    :ok
  end

  defp build_machine_specs(%Model{} = topology, opts) do
    signal_sink = Keyword.get(opts, :signal_sink)
    machine_overrides = Keyword.get(opts, :machine_opts, %{})
    hardware_config = Keyword.get(opts, :hardware_config)

    Enum.reduce_while(topology.machines, {:ok, []}, fn spec, {:ok, acc} ->
      override_opts = Map.get(machine_overrides, spec.name, [])

      case runtime_wiring_opts(Map.get(spec, :wiring), hardware_config, spec.name) do
        {:ok, wiring_opts} ->
          machine_opts =
            spec
            |> Map.get(:opts, [])
            |> Keyword.merge(override_opts)
            |> Keyword.merge(wiring_opts)
            |> Keyword.put(:machine_id, spec.name)
            |> Keyword.put(:topology_id, topology.topology_id)
            |> Keyword.put(:name, Ogol.Topology.Registry.via(spec.name))
            |> Keyword.put(:signal_sink, signal_sink)

          child_spec =
            Supervisor.child_spec({spec.module, machine_opts},
              id: {:ogol_machine, spec.name},
              restart: Map.get(spec, :restart, :permanent)
            )

          {:cont, {:ok, acc ++ [child_spec]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_topology_wiring, spec.name, reason}}}
      end
    end)
  end

  defp runtime_wiring_opts(nil, _hardware_config, _machine_name), do: {:ok, []}

  defp runtime_wiring_opts(wiring, _hardware_config, _machine_name)
       when is_struct(wiring, Ogol.Topology.Wiring) and wiring.facts == %{} and
              wiring.outputs == %{} and wiring.commands == %{} and is_nil(wiring.event_name) do
    {:ok, []}
  end

  defp runtime_wiring_opts(wiring, nil, _machine_name),
    do: {:error, {:missing_hardware_config, wiring}}

  defp runtime_wiring_opts(%Ogol.Topology.Wiring{} = wiring, hardware_config, _machine_name) do
    case Ogol.Hardware.resolve_wiring(wiring, hardware_config) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, {adapter, binding}} ->
        {:ok, [io_adapter: adapter, io_binding: binding]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp stop_if_alive(_pid), do: :ok
end
