defmodule Ogol.HMI.Surface.Deployments do
  @moduledoc false

  alias Ogol.HMI.Surface.DeploymentStore, as: SurfaceDeploymentStore
  alias Ogol.HMI.Surface.Deployment
  alias Ogol.HMI.Surface.Builtins.OperationsOverview

  @default_panel :primary_runtime_panel

  @defaults [
    %Deployment{
      panel_id: @default_panel,
      surface_id: :operations_overview,
      surface_module: OperationsOverview,
      surface_version: "current",
      default_screen: :procedures,
      viewport_profile: :panel_1920x1080
    }
  ]

  def default_panel, do: @default_panel
  def defaults, do: @defaults

  def list, do: SurfaceDeploymentStore.list()

  def default_assignment, do: SurfaceDeploymentStore.default_assignment()

  def fetch_panel(panel_id) do
    SurfaceDeploymentStore.fetch_panel(panel_id)
  end

  def fetch_surface_assignment(surface_id) do
    SurfaceDeploymentStore.fetch_surface_assignment(surface_id)
  end

  def assign_panel(panel_id, surface_id, opts \\ []) do
    SurfaceDeploymentStore.assign_panel(panel_id, surface_id, opts)
  end
end
