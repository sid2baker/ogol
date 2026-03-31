defmodule Ogol.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: Ogol.HMI.PubSub},
      Ogol.Machine.Registry,
      Ogol.Topology.Registry,
      Ogol.Studio.WorkspaceStore,
      Ogol.Studio.RevisionStore,
      Ogol.Hardware.EtherCAT.RuntimeOwner,
      Ogol.HMI.HardwareReleaseStore,
      Ogol.HMI.HardwareSupportSnapshotStore,
      Ogol.HMI.SurfaceRuntimeStore,
      Ogol.HMI.SurfaceDeploymentStore,
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
