defmodule Ogol.HMI.TopologyStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Examples
  alias Ogol.Studio.Revisions
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.TestSupport.EthercatHmiFixture

  test "renders the singleton topology studio cell with the global revision selector" do
    {:ok, view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Topology Studio"
    assert html =~ "Packaging Line topology"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert has_element?(view, "[data-test='topology-view-visual']")
    assert has_element?(view, "[data-test='studio-revision-selector']")
    refute html =~ ">Topologies<"
    refute html =~ "New"
  end

  test "switches to source mode in place for the selected topology" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    assert html =~ "defmodule Ogol.Generated.Topologies.PackagingLine do"
    assert html =~ "use Ogol.Topology"
  end

  test "draft topology studio ignores the active runtime and stays on the current workspace" do
    boot_ethercat_master!()

    assert {:ok, _result} = Ogol.Studio.RuntimeStore.compile_topology("pack_and_inspect_cell")
    assert {:ok, _result} = Ogol.Studio.RuntimeStore.start_topology("pack_and_inspect_cell")

    {:ok, _view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Packaging Line topology"
    assert html =~ "packaging_line"
    refute html =~ "Pack and inspect cell runtime"
  end

  test "revision query loads topology into the shared workspace session instead of reading the active runtime" do
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

    assert {:ok, %Revisions.Revision{id: "r1"}} =
             Revisions.deploy_current(app_id: "ogol")

    draft_model =
      WorkspaceStore.fetch_topology("packaging_line").model
      |> Map.put(:meaning, "Packaging Line Draft Topology")

    WorkspaceStore.save_topology_source(
      "packaging_line",
      Ogol.Topology.Source.to_source(draft_model),
      draft_model,
      :synced,
      []
    )

    assert :ok = Ogol.Studio.TopologyRuntime.stop_active()
    boot_ethercat_master!()

    assert {:ok, _result} = Ogol.Studio.RuntimeStore.compile_topology("pack_and_inspect_cell")
    assert {:ok, _result} = Ogol.Studio.RuntimeStore.start_topology("pack_and_inspect_cell")

    {:ok, _view, html} = live(build_conn(), "/studio/topology?revision=r1")

    assert html =~ "Packaging Line Revision Topology"
    refute html =~ "Pack and inspect cell runtime"

    assert WorkspaceStore.fetch_topology("packaging_line").model.meaning ==
             "Packaging Line Revision Topology"
  end

  test "machine module selection lists available machine drafts" do
    {:ok, view, html} = live(build_conn(), "/studio/topology")

    assert html =~ ~s(select name="topology[machines][0][module_name]")
    assert html =~ ~s(value="Ogol.Generated.Machines.PackagingLine")
    assert html =~ ~s(value="Ogol.Generated.Machines.InspectionCell")
    assert html =~ "Inspection cell coordinator (inspection_cell)"
    assert has_element?(view, ~s(select[name="topology[machines][0][module_name]"]))
  end

  test "start stays clickable and explains why it is blocked before compile" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    refute has_element?(view, ~s(button[phx-value-transition="start"][disabled]))

    render_click(view, "request_transition", %{"transition" => "start"})

    html = render(view)

    assert html =~ "Start blocked"
    assert html =~ "Compile the current topology source before starting it."
  end

  test "adds a new machine draft to the selected topology from the visual editor" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_click(view, "add_topology_machine", %{})

    assert WorkspaceStore.fetch_machine("machine_1")
    assert has_element?(view, ~s(input[name="topology[machines][1][name]"][value="machine_1"]))

    assert has_element?(
             view,
             ~s(select[name="topology[machines][1][module_name]"] option[selected][value="Ogol.Generated.Machines.Machine1"])
           )

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    assert html =~ "machine(:machine_1, Ogol.Generated.Machines.Machine1"
  end

  test "removes a topology machine row in place" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_click(view, "add_topology_machine", %{})
    render_click(view, "remove_topology_machine", %{"index" => "1"})

    refute has_element?(view, ~s(input[name="topology[machines][1][name]"][value="machine_1"]))

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    refute html =~ "machine(:machine_1, Ogol.Generated.Machines.Machine1"
  end

  test "starts and stops the selected topology from the studio cell actions" do
    boot_ethercat_master!()

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})

    assert %{topology_id: :packaging_line} = Ogol.Topology.Registry.active_topology()
    assert has_element?(view, ~s(button[phx-value-transition="stop"]))
    assert render(view) =~ "Running"

    render_click(view, "request_transition", %{"transition" => "stop"})

    html = render(view)

    assert html =~ "Start"
    refute html =~ "Stop"
    assert Ogol.Topology.Registry.active_topology() == nil
  end

  test "watering example start uses its imported hardware config" do
    assert {:ok, _example, _revision_file, _report} =
             Examples.load_into_workspace("watering_valves")

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})

    assert %{topology_id: :watering_system} = Ogol.Topology.Registry.active_topology()
  end

  test "falls back to source mode when the topology source leaves the supported subset" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    unsupported_source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology
      alias Custom.Helper

      topology do
        strategy(:one_for_one)
      end

      machines do
        machine(:packaging_line, Ogol.Generated.Machines.PackagingLine)
      end
    end
    """

    render_change(view, "change_source", %{"draft" => %{"source" => unsupported_source}})

    html = render(view)

    assert html =~ "Visual editor unavailable"
    assert html =~ "must only define `use`, `topology`, and `machines`"
    assert html =~ "alias Custom.Helper"
  end

  test "loads persisted parser diagnostics without crashing the topology page" do
    bad_source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology

      topology do
        strategy(:one_for_one)
    end
    """

    WorkspaceStore.save_topology_source(
      "packaging_line",
      bad_source,
      nil,
      :unsupported,
      [
        {[
           line: 5,
           column: 5,
           end_line: 6,
           end_column: 1,
           error_type: :mismatched_delimiter,
           opening_delimiter: :"(",
           closing_delimiter: :end,
           expected_delimiter: :")"
         ], "unexpected reserved word: ", "end"}
      ]
    )

    {:ok, _view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Visual editor unavailable"
    assert html =~ "Topology Studio"
  end

  test "visual edits update the selected topology draft" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_change(view, "change_visual", %{
      "topology" => %{
        "topology_id" => "packaging_line",
        "module_name" => "Ogol.Generated.Topologies.PackagingLine",
        "strategy" => "one_for_all",
        "meaning" => "Packaging line runtime topology",
        "machine_count" => "2",
        "machines" => %{
          "0" => %{
            "name" => "packaging_line",
            "module_name" => "Ogol.Generated.Machines.PackagingLine",
            "restart" => "permanent",
            "meaning" => "Packaging line coordinator"
          },
          "1" => %{
            "name" => "inspection_cell",
            "module_name" => "Ogol.Generated.Machines.InspectionCell",
            "restart" => "transient",
            "meaning" => "Inspection coordinator"
          }
        }
      }
    })

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    assert html =~ "Packaging line runtime topology"
    assert html =~ "strategy(:one_for_all)"
    assert html =~ "machine(:inspection_cell, Ogol.Generated.Machines.InspectionCell"
  end

  defp boot_ethercat_master! do
    EthercatHmiFixture.boot_preop_ring!()
  end

  defp compile_topology(view) do
    render_click(view, "request_transition", %{"transition" => "compile"})
  end
end
