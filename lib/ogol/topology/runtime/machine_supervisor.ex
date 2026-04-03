defmodule Ogol.Topology.Runtime.MachineSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) when is_list(opts) do
    children = Keyword.get(opts, :children, [])
    strategy = Keyword.get(opts, :strategy, :one_for_one)

    Supervisor.start_link(__MODULE__, {children, strategy})
  end

  @impl true
  def init({children, strategy}) when is_list(children) do
    Supervisor.init(children, strategy: strategy)
  end
end
