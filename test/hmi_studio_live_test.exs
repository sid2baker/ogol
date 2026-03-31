defmodule Ogol.HMI.HmiStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.{SurfaceDeploymentStore, SurfaceDraftStore}
  alias Ogol.Studio.RevisionStore
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.WorkspaceStore.TopologyDraft
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.Topology.Runtime

  setup do
    SurfaceDraftStore.reset()
    SurfaceDeploymentStore.reset()
    :ok
  end

  test "shows a topology-scoped HMI workspace for the current draft bundle" do
    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Packaging Line topology"
    assert html =~ "Screens"
    assert html =~ "Packaging Line topology Overview"
    assert html =~ "Packaging Line coordinator Station"
    assert html =~ "Compile"
    assert html =~ "Configuration"
    assert html =~ "Preview"
    assert html =~ "Source"
    assert html =~ "Connected to the active topology runtime summary for packaging_line."
    refute html =~ "Save Draft"
    refute html =~ "Published runtime"
    refute html =~ "Panel assignment target"
    refute html =~ "Col Span"
    refute html =~ "Row Span"
  end

  test "shows a clear empty state when the current draft bundle has no topology" do
    WorkspaceStore.replace_topologies([])

    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Add a topology to author HMI cells"
    assert html =~ "/studio/topology"
  end

  test "draft HMI workspace ignores the active topology runtime and stays on the current draft bundle" do
    EthercatHmiFixture.boot_preop_ring!()
    assert {:ok, _result} = WorkspaceStore.compile_topology("pack_and_inspect_cell")
    assert {:ok, %{pid: pid}} = WorkspaceStore.start_topology("pack_and_inspect_cell")

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
      EthercatHmiFixture.stop_all!()
    end)

    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Packaging Line topology"
    assert html =~ "Packaging Line topology Overview"
    refute html =~ "Pack and inspect cell topology"
  end

  test "revision query builds the HMI workspace from the shared session after loading that revision" do
    revision_model =
      WorkspaceStore.fetch_topology("packaging_line").model
      |> Map.put(:meaning, "Packaging Line Revision Topology")

    WorkspaceStore.save_topology_source(
      "packaging_line",
      Ogol.Topology.Source.to_source(revision_model),
      revision_model,
      :synced,
      []
    )

    assert {:ok, %RevisionStore.Revision{id: "r1"}} =
             RevisionStore.deploy_current(app_id: "ogol_bundle")

    assert :ok = Ogol.Studio.TopologyRuntime.stop_active()
    EthercatHmiFixture.boot_preop_ring!()
    assert {:ok, _result} = WorkspaceStore.compile_topology("pack_and_inspect_cell")
    assert {:ok, %{pid: pid}} = WorkspaceStore.start_topology("pack_and_inspect_cell")

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
      EthercatHmiFixture.stop_all!()
    end)

    {:ok, _view, html} = live(build_conn(), "/studio/hmis?revision=r1")

    assert html =~ "Packaging Line Revision Topology"
    assert html =~ "Packaging Line Revision Topology Overview"
    refute html =~ "Pack and inspect cell topology"

    assert WorkspaceStore.fetch_topology("packaging_line").model.meaning ==
             "Packaging Line Revision Topology"
  end

  test "draft HMI workspace follows the current draft bundle instead of the active runtime" do
    WorkspaceStore.replace_topologies([
      %TopologyDraft{
        id: "watering_system",
        source: """
        defmodule Ogol.Generated.Topologies.WateringSystem do
          use Ogol.Topology

          topology do
            root(:packaging_line)
            strategy(:one_for_one)
            meaning("Watering Bundle Topology")

            machine(:packaging_line, Ogol.Generated.Machines.PackagingLine,
              restart: :permanent,
              meaning: "Watering line"
            )
          end
        end
        """,
        model: %Ogol.Topology.Model{
          root: :packaging_line,
          strategy: :one_for_one,
          meaning: "Watering Bundle Topology",
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

    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Watering Bundle Topology"
    assert html =~ "Watering Bundle Topology Overview"
    refute html =~ "Simple HMI Studio Line"
  end

  test "compiled topology-scoped surfaces affect runtime only after assignment" do
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
end
