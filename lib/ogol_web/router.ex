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
    live("/studio/simulator/:adapter_id", Studio.SimulatorLive, :show)
    live("/studio/simulator/:adapter_id/:view", Studio.SimulatorLive, :show)
    live("/studio/hardware", Studio.HardwareLive, :index)
    live("/studio/hardware/:adapter_id", Studio.HardwareLive, :show)
    live("/studio/hardware/:adapter_id/:view", Studio.HardwareLive, :show)
    live("/studio/sequences", Studio.SequenceLive, :index)
    live("/studio/sequences/:sequence_id", Studio.SequenceLive, :show)
    live("/studio/sequences/:sequence_id/:view", Studio.SequenceLive, :show)
    live("/studio/machines", Studio.MachineLive, :index)
    live("/studio/machines/:machine_id", Studio.MachineLive, :show)
    live("/studio/machines/:machine_id/:view", Studio.MachineLive, :show)
    live("/studio/topology", Studio.TopologyLive, :show)
    live("/studio/topology/:view", Studio.TopologyLive, :show)

    live_session :studio_cells, layout: {OgolWeb.Layouts, :cell} do
      live("/studio/cells/hmis/:surface_id", Studio.HmiLive, :cell)
      live("/studio/cells/simulator/:adapter_id", Studio.SimulatorLive, :cell)
      live("/studio/cells/simulator/:adapter_id/:view", Studio.SimulatorLive, :cell)
      live("/studio/cells/hardware/:adapter_id", Studio.HardwareLive, :cell)
      live("/studio/cells/hardware/:adapter_id/:view", Studio.HardwareLive, :cell)
      live("/studio/cells/sequences/:sequence_id", Studio.SequenceLive, :cell)
      live("/studio/cells/sequences/:sequence_id/:view", Studio.SequenceLive, :cell)
      live("/studio/cells/machines/:machine_id", Studio.MachineLive, :cell)
      live("/studio/cells/machines/:machine_id/:view", Studio.MachineLive, :cell)
      live("/studio/cells/topology", Studio.TopologyLive, :cell)
      live("/studio/cells/topology/:view", Studio.TopologyLive, :cell)
    end

    get("/studio/revision_file/download", Studio.RevisionFileController, :download)

    get(
      "/studio/hardware/support_snapshots/:id/download",
      Studio.HardwareSupportSnapshotController,
      :download
    )
  end
end
