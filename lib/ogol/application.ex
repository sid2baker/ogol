defmodule Ogol.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Ogol.HMI.PubSub},
      Ogol.Topology.Registry,
      Ogol.HMI.RuntimeIndex,
      Ogol.HMI.HardwareConfigStore,
      Ogol.HMI.SnapshotStore,
      Ogol.HMI.EventLog,
      Ogol.HMI.Projector,
      Ogol.HMIWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Ogol.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    Ogol.HMIWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
