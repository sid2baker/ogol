defmodule Ogol.Topology.Runtime do
  @moduledoc false

  use Supervisor

  alias Ogol.Topology.Plan
  alias Ogol.Topology.Model
  alias Ogol.Topology.Registry
  alias Ogol.Topology.RootSupervisor
  alias Ogol.Topology.Runtime.MachineSupervisor
  alias Ogol.Topology.Runtime.ReadyNotifier

  @root_supervisor RootSupervisor

  @type start_context_t :: Plan.t()

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
      :error -> Plan.build(topology, opts)
    end
  end

  @spec start_context(Model.t(), keyword()) :: {:ok, start_context_t()} | {:error, term()}
  defp start_context(%Model{} = topology, opts), do: Plan.build(topology, opts)

  defp claim_topology!(module, topology_scope) when is_atom(module) and is_atom(topology_scope) do
    case Registry.claim_topology(%{module: module, topology_scope: topology_scope}) do
      :ok ->
        :ok

      {:error, reason} ->
        exit({:shutdown, reason})
    end
  end
end
