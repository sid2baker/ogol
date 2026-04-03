defmodule Ogol.Topology.Runtime do
  @moduledoc false

  use Supervisor

  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATConfig
  alias Ogol.Hardware.EtherCAT.Adapter, as: EtherCATAdapter
  alias Ogol.Hardware.EtherCAT.RuntimeHost, as: EtherCATRuntimeHost
  alias Ogol.Hardware.EtherCAT.TopologySession, as: EtherCATTopologySession
  alias Ogol.Topology
  alias Ogol.Topology.Model
  alias Ogol.Topology.Registry
  alias Ogol.Topology.RootSupervisor
  alias Ogol.Topology.Runtime.MachineSupervisor
  alias Ogol.Topology.Runtime.ReadyNotifier

  @root_supervisor RootSupervisor

  @type start_context_t :: %{
          topology_scope: atom(),
          machine_specs: [Supervisor.child_spec()],
          hardware_children: [Supervisor.child_spec()]
        }

  @spec child_spec({Model.t(), keyword()}) :: Supervisor.child_spec()
  def child_spec({%Model{} = topology, opts}) when is_list(opts) do
    %{
      id: {__MODULE__, topology.module},
      start: {__MODULE__, :start_link, [topology, opts]},
      restart: :temporary,
      type: :supervisor
    }
  end

  @spec start_link(Model.t(), keyword()) :: Supervisor.on_start()
  def start_link(%Model{} = topology, opts \\ []) do
    with {:ok, context} <- start_context_from_opts(topology, opts) do
      Supervisor.start_link(__MODULE__, {topology, context}, name: Keyword.get(opts, :name))
    end
  end

  @spec start(Model.t(), keyword()) :: DynamicSupervisor.on_start_child()
  def start(%Model{} = topology, opts \\ []) do
    with {:ok, context} <- start_context(topology, opts) do
      child_opts = Keyword.put(opts, :start_context, context)
      DynamicSupervisor.start_child(@root_supervisor, {__MODULE__, {topology, child_opts}})
    end
  end

  @spec machine_pid(pid() | atom(), atom()) :: pid() | nil
  def machine_pid(_topology, name) when is_atom(name) do
    Registry.whereis(name)
  end

  @impl true
  def init({%Model{} = topology, %{topology_scope: topology_scope} = context}) do
    claim_topology!(topology.module, topology_scope)

    children =
      context.hardware_children ++
        [
          {MachineSupervisor, children: context.machine_specs, strategy: topology.strategy},
          {ReadyNotifier, module: topology.module, topology_scope: topology_scope}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp start_context_from_opts(%Model{} = topology, opts) do
    case Keyword.fetch(opts, :start_context) do
      {:ok, context} -> {:ok, context}
      :error -> start_context(topology, opts)
    end
  end

  @spec start_context(Model.t(), keyword()) :: {:ok, start_context_t()} | {:error, term()}
  defp start_context(%Model{} = topology, opts) do
    topology_scope = Topology.scope(topology.module)
    signal_sink = Keyword.get(opts, :signal_sink)
    machine_overrides = Keyword.get(opts, :machine_opts, %{})
    hardware_configs = Keyword.get(opts, :hardware_configs, %{})

    with {:ok, machine_specs, required_hardware} <-
           build_machine_specs(
             topology,
             signal_sink,
             machine_overrides,
             hardware_configs,
             topology_scope
           ),
         {:ok, hardware_children} <- hardware_child_specs(required_hardware) do
      {:ok,
       %{
         topology_scope: topology_scope,
         machine_specs: machine_specs,
         hardware_children: hardware_children
       }}
    end
  end

  defp claim_topology!(module, topology_scope) when is_atom(module) and is_atom(topology_scope) do
    case Registry.claim_topology(%{module: module, topology_scope: topology_scope}) do
      :ok ->
        :ok

      {:error, reason} ->
        exit({:shutdown, reason})
    end
  end

  defp build_machine_specs(
         %Model{} = topology,
         signal_sink,
         machine_overrides,
         hardware_configs,
         topology_scope
       ) do
    Enum.reduce_while(topology.machines, {:ok, [], %{}}, fn spec, {:ok, acc, required_hardware} ->
      override_opts = Map.get(machine_overrides, spec.name, [])

      case resolve_machine_wiring_opts(Map.get(spec, :wiring), hardware_configs) do
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

  defp resolve_machine_wiring_opts(nil, _hardware_configs), do: {:ok, [], %{}}

  defp resolve_machine_wiring_opts(wiring, _hardware_configs)
       when is_struct(wiring, Ogol.Topology.Wiring) and wiring.facts == %{} and
              wiring.outputs == %{} and wiring.commands == %{} and is_nil(wiring.event_name) do
    {:ok, [], %{}}
  end

  defp resolve_machine_wiring_opts(wiring, hardware_configs) when hardware_configs == %{},
    do: {:error, {:missing_hardware_config, wiring}}

  defp resolve_machine_wiring_opts(%Ogol.Topology.Wiring{} = wiring, hardware_configs) do
    case Ogol.Hardware.resolve_wiring(wiring, hardware_configs) do
      {:ok, nil} ->
        {:ok, [], %{}}

      {:ok, {adapter, binding}} ->
        with {:ok, required_configs} <- required_hardware_configs(adapter, hardware_configs) do
          {:ok, [io_adapter: adapter, io_binding: binding], required_configs}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp required_hardware_configs(EtherCATAdapter, %{"ethercat" => %EtherCATConfig{} = config}) do
    {:ok, %{"ethercat" => config}}
  end

  defp required_hardware_configs(EtherCATAdapter, _hardware_configs) do
    {:error, :no_hardware_config_available}
  end

  defp required_hardware_configs(_adapter, _hardware_configs) do
    {:error, :unsupported_hardware_adapter}
  end

  defp hardware_child_specs(required_hardware) when required_hardware == %{}, do: {:ok, []}

  defp hardware_child_specs(required_hardware) when is_map(required_hardware) do
    required_hardware
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {config_id, config}, {:ok, acc} ->
      case hardware_child_specs(config_id, config) do
        {:ok, child_specs} ->
          {:cont, {:ok, acc ++ child_specs}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp hardware_child_specs("ethercat", %EtherCATConfig{} = config) do
    {:ok,
     [
       Supervisor.child_spec({EtherCATRuntimeHost, []},
         id: {:ogol_hardware_runtime, :ethercat},
         type: :supervisor
       ),
       Supervisor.child_spec({EtherCATTopologySession, config: config},
         id: {:ogol_hardware_session, :ethercat}
       )
     ]}
  end

  defp hardware_child_specs(config_id, _config) do
    {:error, {:unsupported_hardware_config, config_id}}
  end
end
