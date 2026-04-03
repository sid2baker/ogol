defmodule Ogol.Topology.Runtime.ReadyNotifier do
  @moduledoc false

  use GenServer

  alias Ogol.Runtime.Notifier

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    module = Keyword.fetch!(opts, :module)
    topology_scope = Keyword.fetch!(opts, :topology_scope)

    Notifier.emit(:topology_ready,
      machine_id: topology_scope,
      topology_id: topology_scope,
      source: module,
      payload: %{topology_id: topology_scope},
      meta: %{pid: self(), module: module}
    )

    {:ok, %{module: module, topology_scope: topology_scope}}
  end
end
