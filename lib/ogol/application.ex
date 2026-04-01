defmodule Ogol.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Ogol.Runtime.PubSub},
      Ogol.Machine.Registry,
      Ogol.Topology.Registry,
      Ogol.Session,
      Ogol.Runtime.Deployment,
      Ogol.Hardware.EtherCAT.RuntimeOwner,
      Ogol.Runtime.Hardware.ReleaseStore,
      Ogol.Runtime.Hardware.SupportSnapshotStore,
      Ogol.HMI.Surface.RuntimeStore,
      Ogol.HMI.Surface.DeploymentStore,
      Ogol.Runtime.SnapshotStore,
      Ogol.Runtime.EventLog,
      Ogol.Runtime.Projector,
      OgolWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Ogol.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    OgolWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
