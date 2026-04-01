defmodule OgolWeb.Router do
  use OgolWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {OgolWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", OgolWeb do
    pipe_through(:browser)

    get("/", PageController, :root)

    live("/ops", HMI.SurfaceLive, :assigned)
    live("/ops/hmis", HMI.SurfaceIndexLive, :index)
    live("/ops/hmis/:surface_id", HMI.SurfaceLive, :show)
    live("/ops/hmis/:surface_id/:screen_id", HMI.SurfaceLive, :show)
    live("/ops/machines/:machine_id", HMI.MachineLive, :show)

    live("/studio", Studio.IndexLive, :index)
    live("/studio/hmis", Studio.HmiLive, :index)
    live("/studio/hmis/:surface_id", Studio.HmiLive, :show)
    live("/studio/simulator", Studio.SimulatorLive, :index)
    live("/studio/hardware", Studio.HardwareLive, :index)
    live("/studio/drivers", Studio.DriverLive, :index)
    live("/studio/drivers/:driver_id", Studio.DriverLive, :show)
    live("/studio/sequences", Studio.SequenceLive, :index)
    live("/studio/sequences/:sequence_id", Studio.SequenceLive, :show)
    live("/studio/machines", Studio.MachineLive, :index)
    live("/studio/machines/:machine_id", Studio.MachineLive, :show)
    live("/studio/topology", Studio.TopologyLive, :index)
    get("/studio/revision_file/download", Studio.RevisionFileController, :download)

    get(
      "/studio/hardware/support_snapshots/:id/download",
      Studio.HardwareSupportSnapshotController,
      :download
    )
  end
end
