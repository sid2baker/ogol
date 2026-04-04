defmodule Ogol.Sequence.RuntimeSupervisor do
  @moduledoc false

  use DynamicSupervisor

  @type topology_scope :: atom()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    topology_scope = Keyword.fetch!(opts, :topology_scope)

    %{
      id: {__MODULE__, topology_scope},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    topology_scope = Keyword.fetch!(opts, :topology_scope)
    DynamicSupervisor.start_link(__MODULE__, opts, name: via(topology_scope))
  end

  @spec via(topology_scope()) :: {:via, Registry, {module(), term()}}
  def via(topology_scope) when is_atom(topology_scope) do
    {:via, Registry, {Ogol.Topology.Registry, {:sequence_runtime_supervisor, topology_scope}}}
  end

  @spec whereis(topology_scope()) :: pid() | nil
  def whereis(topology_scope) when is_atom(topology_scope) do
    case Registry.lookup(Ogol.Topology.Registry, {:sequence_runtime_supervisor, topology_scope}) do
      [{pid, _value}] when is_pid(pid) -> pid
      [] -> nil
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
