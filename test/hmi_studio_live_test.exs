defmodule Ogol.HMI.HmiStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.{SurfaceDeploymentStore, SurfaceDraftStore}
  alias Ogol.Studio.TopologyDraftStore
  alias Ogol.Studio.TopologyRuntime
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.Topology.Runtime

  setup do
    SurfaceDraftStore.reset()
    SurfaceDeploymentStore.reset()
    :ok
  end

  test "shows a topology-scoped HMI workspace when a topology is active" do
    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Simple HMI Studio Line"
    assert html =~ "Screens"
    assert html =~ "Simple HMI Studio Line Overview"
    assert html =~ "Minimal Spark-backed sample machine Station"
    assert html =~ "Compile"
    assert html =~ "Configuration"
    assert html =~ "Preview"
    assert html =~ "Source"
    assert html =~ "Connected to the active topology runtime summary for simple_hmi_line."
    refute html =~ "Save Draft"
    refute html =~ "Published runtime"
    refute html =~ "Panel assignment target"
    refute html =~ "Col Span"
    refute html =~ "Row Span"
  end

  test "shows a clear empty state when no topology is active" do
    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Start a topology to author HMI cells"
    assert html =~ "/studio/topology"
  end

  test "shows seeded HMI cells for the pack and inspect topology once it is active" do
    EthercatHmiFixture.boot_preop_ring!()
    draft = TopologyDraftStore.fetch("pack_and_inspect_cell")

    assert {:ok, %{pid: pid}} =
             TopologyRuntime.start("pack_and_inspect_cell", draft.source, draft.model)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
      EthercatHmiFixture.stop_all!()
    end)

    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Pack and inspect cell topology"
    assert html =~ "Pack and inspect cell topology Overview"
    assert html =~ "Pack and inspect cell coordinator Station"
    assert html =~ "Inspection station Station"
  end

  test "compiled topology-scoped surfaces affect runtime only after assignment" do
    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    end)

    {:ok, view, _html} = live(build_conn(), "/studio/hmis/topology_simple_hmi_line_overview")

    view
    |> element("#hmi-cell-topology_simple_hmi_line_overview form[phx-change='change_metadata']")
    |> render_change(%{
      "surface" => %{
        "title" => "Topology Runtime Version One",
        "summary" => "First topology-scoped runtime surface."
      }
    })

    assert render(view) =~ "Topology Runtime Version One"

    view
    |> element("#hmi-cell-topology_simple_hmi_line_overview button", "Compile")
    |> render_click()

    view
    |> element("#hmi-cell-topology_simple_hmi_line_overview button", "Deploy")
    |> render_click()

    {:ok, _runtime_view, runtime_html_before} = live(build_conn(), "/ops")

    refute runtime_html_before =~ "Topology Runtime Version One"

    view
    |> element("#hmi-cell-topology_simple_hmi_line_overview button", "Assign Panel")
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

    {:ok, view, _html} = live(build_conn(), "/studio/hmis/topology_simple_hmi_line_overview")

    view
    |> element(
      "#hmi-cell-topology_simple_hmi_line_overview form[phx-change='change_zone_config']"
    )
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
      |> element("#hmi-cell-topology_simple_hmi_line_overview button", "Preview")
      |> render_click()

    assert html =~ "Runtime posture at a glance"
    assert html =~ "Machines"
  end
end
