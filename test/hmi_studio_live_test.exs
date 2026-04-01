defmodule Ogol.HMI.HmiStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.Surface.Compiler, as: SurfaceCompiler
  alias Ogol.HMI.Surface.DeploymentStore, as: SurfaceDeploymentStore
  alias Ogol.Session.Revisions
  alias Ogol.Session
  alias Ogol.Session.Data.TopologyDraft
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.Topology.Runtime

  setup do
    SurfaceDeploymentStore.reset()
    :ok
  end

  test "shows workspace-backed HMI source instead of deriving screens from topology" do
    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Workspace-backed HMI surfaces"
    assert html =~ "Screens"
    assert html =~ "Packaging Line topology Overview"
    assert html =~ "Station"
    assert html =~ "Compile"
    assert html =~ "Configuration"
    assert html =~ "Preview"
    assert html =~ "Source"
  end

  test "shows a clear empty state when the workspace has no HMI source" do
    Session.replace_hmi_surfaces([])

    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "No HMI source is in the workspace"
    assert html =~ "Generate surfaces from the current topology"
  end

  test "generate from topology creates source-backed HMI surfaces explicitly" do
    Session.replace_hmi_surfaces([])

    Session.replace_topologies([
      %TopologyDraft{
        id: "watering_system",
        source: """
        defmodule Ogol.Generated.Topologies.WateringSystem do
          use Ogol.Topology

          topology do
            strategy(:one_for_one)
            meaning("Watering Revision Topology")
          end

          machines do
            machine(:packaging_line, Ogol.Generated.Machines.PackagingLine,
              restart: :permanent,
              meaning: "Watering line"
            )
          end
        end
        """,
        model: %Ogol.Topology.Model{
          module: Ogol.Generated.Topologies.WateringSystem,
          topology_id: :watering_system,
          strategy: :one_for_one,
          meaning: "Watering Revision Topology",
          machines: [
            %{
              name: :packaging_line,
              module: Ogol.Generated.Machines.PackagingLine,
              meaning: "Watering line"
            }
          ]
        },
        sync_state: :synced,
        sync_diagnostics: []
      }
    ])

    {:ok, view, html} = live(build_conn(), "/studio/hmis")
    assert html =~ "No HMI source is in the workspace"

    html =
      view
      |> element("button", "Generate From Current Topology")
      |> render_click()

    assert html =~ "Watering Revision Topology Overview"
    assert html =~ "Watering line Station"
  end

  test "revision query loads workspace HMI source from that revision" do
    update_surface_title!("topology_packaging_line_overview", "Packaging Line Revision Overview")

    assert {:ok, %Revisions.Revision{id: "r1"}} =
             Revisions.deploy_current(app_id: "ogol")

    update_surface_title!("topology_packaging_line_overview", "Packaging Line Draft Overview")

    {:ok, _view, html} = live(build_conn(), "/studio/hmis?revision=r1")

    assert html =~ "Packaging Line Revision Overview"
    refute html =~ "Packaging Line Draft Overview"

    assert Session.fetch_hmi_surface("topology_packaging_line_overview").model.title ==
             "Packaging Line Revision Overview"
  end

  test "workspace HMI source stays on the current workspace instead of the active runtime" do
    EthercatHmiFixture.boot_preop_ring!()
    assert {:ok, _result} = Ogol.Runtime.compile_topology("pack_and_inspect_cell")

    assert {:ok, %{pid: pid}} =
             Ogol.Runtime.deploy_topology("pack_and_inspect_cell")

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
      EthercatHmiFixture.stop_all!()
    end)

    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Packaging Line topology Overview"
    refute html =~ "Pack and inspect cell topology"
  end

  test "compiled workspace surfaces affect runtime only after assignment" do
    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    {:ok, view, _html} = live(build_conn(), "/studio/hmis/topology_packaging_line_overview")

    view
    |> element("#hmi-cell-topology_packaging_line_overview form[phx-change='change_metadata']")
    |> render_change(%{
      "surface" => %{
        "title" => "Topology Runtime Version One",
        "summary" => "First topology-scoped runtime surface."
      }
    })

    assert render(view) =~ "Topology Runtime Version One"

    view
    |> element("#hmi-cell-topology_packaging_line_overview button", "Compile")
    |> render_click()

    view
    |> element("#hmi-cell-topology_packaging_line_overview button", "Deploy")
    |> render_click()

    {:ok, _runtime_view, runtime_html_before} = live(build_conn(), "/ops")
    refute runtime_html_before =~ "Topology Runtime Version One"

    view
    |> element("#hmi-cell-topology_packaging_line_overview button", "Assign Panel")
    |> render_click()

    {:ok, _runtime_view, runtime_html_after} = live(build_conn(), "/ops")

    assert runtime_html_after =~ "Topology Runtime Version One"
    assert runtime_html_after =~ "r1"
  end

  test "preview stays up when a widget is bound to an incompatible source" do
    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    {:ok, view, _html} = live(build_conn(), "/studio/hmis/topology_packaging_line_overview")

    view
    |> element("#hmi-cell-topology_packaging_line_overview form[phx-change='change_zone_config']")
    |> render_change(%{
      "zones" => %{
        "status_rail" => %{
          "type" => "summary_strip",
          "binding" => "alarm_summary"
        }
      }
    })

    html =
      view
      |> element("#hmi-cell-topology_packaging_line_overview button", "Preview")
      |> render_click()

    assert html =~ "Runtime posture at a glance"
    assert html =~ "Machines"
  end

  defp update_surface_title!(surface_id, title) do
    draft = Session.fetch_hmi_surface(surface_id)
    source = String.replace(draft.source, draft.model.title, title)
    analysis = SurfaceCompiler.analyze(source)

    assert analysis.classification == :visual

    Session.save_hmi_surface_source(
      surface_id,
      source,
      draft.source_module,
      analysis.definition,
      :synced,
      analysis.diagnostics
    )
  end
end
