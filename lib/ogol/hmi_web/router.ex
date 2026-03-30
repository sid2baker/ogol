defmodule Ogol.HMIWeb.Router do
  use Ogol.HMIWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {Ogol.HMIWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", Ogol.HMIWeb do
    pipe_through(:browser)

    get("/", PageController, :root)

    live("/ops", SurfaceLive, :assigned)
    live("/ops/hmis", SurfaceIndexLive, :index)
    live("/ops/hmis/:surface_id", SurfaceLive, :show)
    live("/ops/hmis/:surface_id/:screen_id", SurfaceLive, :show)
    live("/ops/machines/:machine_id", MachineLive, :show)

    live("/studio", StudioIndexLive, :index)
    live("/studio/examples", StudioExamplesLive, :index)
    live("/studio/hmis", HmiStudioLive, :index)
    live("/studio/hmis/:surface_id", HmiStudioLive, :show)
    live("/studio/simulator", SimulatorLive, :index)
    live("/studio/ethercat", HardwareLive, :index)
    live("/studio/hardware", HardwareLive, :index)
    live("/studio/drivers", DriverStudioLive, :index)
    live("/studio/drivers/:driver_id", DriverStudioLive, :show)
    live("/studio/machines", MachineStudioLive, :index)
    live("/studio/machines/:machine_id", MachineStudioLive, :show)
    live("/studio/topology", TopologyStudioLive, :index)
    get("/studio/bundle/download", StudioBundleController, :download)

    get(
      "/studio/ethercat/support_snapshots/:id/download",
      HardwareSupportSnapshotController,
      :download
    )

    get(
      "/studio/hardware/support_snapshots/:id/download",
      HardwareSupportSnapshotController,
      :download
    )
  end
end
