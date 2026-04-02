defmodule Ogol.HMI.TopologyStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Runtime
  alias Ogol.Studio.Examples
  alias Ogol.Session.Revisions
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.Topology.Source, as: TopologySource

  test "renders the singleton topology studio cell with the global revision selector" do
    {:ok, view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Topology Studio"
    assert html =~ "Packaging Line topology"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "Live"
    assert has_element?(view, "[data-test='topology-view-visual']")
    assert has_element?(view, "[data-test='topology-view-live']")
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

    assert {:ok, _result} = Runtime.compile(:topology, "pack_and_inspect_cell")
    assert {:ok, _result} = Runtime.deploy_topology("pack_and_inspect_cell")

    {:ok, _view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Packaging Line topology"
    assert html =~ "packaging_line"
    refute html =~ "Pack and inspect cell runtime"
  end

  test "revision query loads topology into the shared workspace session instead of reading the active runtime" do
    revision_model =
      Session.fetch_topology("packaging_line").model
      |> Map.put(:meaning, "Packaging Line Revision Topology")

    Session.save_topology_source(
      "packaging_line",
      Ogol.Topology.Source.to_source(revision_model),
      revision_model,
      :synced,
      []
    )

    assert {:ok, %Revisions.Revision{id: "r1"}} =
             Revisions.deploy_current(app_id: "ogol")

    draft_model =
      Session.fetch_topology("packaging_line").model
      |> Map.put(:meaning, "Packaging Line Draft Topology")

    Session.save_topology_source(
      "packaging_line",
      Ogol.Topology.Source.to_source(draft_model),
      draft_model,
      :synced,
      []
    )

    assert :ok = Runtime.stop_active()
    boot_ethercat_master!()

    assert {:ok, _result} = Runtime.compile(:topology, "pack_and_inspect_cell")
    assert {:ok, _result} = Runtime.deploy_topology("pack_and_inspect_cell")

    {:ok, _view, html} = live(build_conn(), "/studio/topology?revision=r1")

    assert html =~ "Packaging Line Revision Topology"
    refute html =~ "Pack and inspect cell runtime"

    assert Session.fetch_topology("packaging_line").model.meaning ==
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

    assert Session.fetch_machine("machine_1")
    assert has_element?(view, ~s(input[name="topology[machines][1][name]"][value="machine_1"]))

    assert has_element?(
             view,
             ~s(select[name="topology[machines][1][module_name]"] option[selected][value="Ogol.Generated.Machines.Machine1"])
           )

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    assert html =~ "machine(:machine_1, Ogol.Generated.Machines.Machine1"
  end

  test "deleting the selected topology patches to the next available topology" do
    draft = Session.create_topology("browser_delete_topology")

    {:ok, view, _html} = live(build_conn(), "/studio/topology?topology=#{draft.id}")

    render_click(view, "request_transition", %{"transition" => "delete"})

    expected_path =
      case Session.list_topologies() do
        [%{id: id} | _rest] -> "/studio/topology?topology=#{id}"
        [] -> "/studio/topology"
      end

    assert_patch(view, expected_path)
    refute Enum.any?(Session.list_topologies(), &(&1.id == draft.id))
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

  test "running topology exposes restart and redeploys through the action boundary" do
    boot_ethercat_master!()

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})

    first_deployment_id = Runtime.active_manifest().deployment_id

    assert has_element?(view, ~s(button[phx-value-transition="restart"]))

    render_click(view, "request_transition", %{"transition" => "restart"})

    assert %{topology_id: :packaging_line} = Ogol.Topology.Registry.active_topology()
    assert Runtime.active_manifest().deployment_id != first_deployment_id
  end

  test "live mode renders running machine instances as tabs and invokes a skill on the selected instance" do
    boot_ethercat_master!()

    topology_model = %{
      topology_id: "packaging_and_inspection",
      module_name: "Ogol.Generated.Topologies.PackagingAndInspection",
      strategy: "one_for_one",
      meaning: "Packaging and inspection runtime",
      machines: [
        %{
          name: "packaging_line",
          module_name: "Ogol.Generated.Machines.PackagingLine",
          restart: "permanent",
          meaning: "Packaging line"
        },
        %{
          name: "inspection_cell",
          module_name: "Ogol.Generated.Machines.InspectionCell",
          restart: "transient",
          meaning: "Inspection cell"
        }
      ]
    }

    Session.save_topology_source(
      topology_model.topology_id,
      TopologySource.to_source(topology_model),
      topology_model,
      :synced,
      []
    )

    {:ok, view, _html} = live(build_conn(), "/studio/topology?topology=packaging_and_inspection")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})
    render_click(view, "select_view", %{"view" => "live"})

    assert has_element?(view, "[data-test='topology-live-machine-packaging_line']")
    assert has_element?(view, "[data-test='topology-live-machine-inspection_cell']")

    render_click(view, "select_live_machine", %{"machine" => "packaging_line"})

    html = render(view)

    assert html =~ "topology-live-machine-mermaid-packaging_line"
    assert html =~ "stateDiagram-v2"

    refute html =~
             "Parse the selected machine into the supported model to render the live state diagram here."

    render_submit(view, "invoke_live_skill", %{
      "machine" => "packaging_line",
      "skill" => "start",
      "args" => %{}
    })

    Process.sleep(50)

    html = render(view)

    assert html =~ "packaging_line :: skill start"
    assert html =~ "reply=:ok"
    assert html =~ "class state_running ogolActive"
  end

  test "watering example start uses its imported hardware config" do
    assert {:ok, _example, _revision_file, _report} =
             Examples.load_into_workspace("watering_valves")

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})

    assert %{topology_id: :watering_system} = Ogol.Topology.Registry.active_topology()
  end

  test "watering example configure_schedule uses typed live skill args" do
    boot_ethercat_master!()

    assert {:ok, _example, _revision_file, _report} =
             Examples.load_into_workspace("watering_valves")

    {:ok, view, _html} = live(build_conn(), "/studio/topology?topology=watering_system")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})
    render_click(view, "select_view", %{"view" => "live"})

    assert has_element?(view, "[data-test='topology-live-machine-watering_controller']")

    render_click(view, "select_live_machine", %{"machine" => "watering_controller"})

    assert has_element?(view, ~s(input[name="args[interval_ms]"]))
    assert has_element?(view, ~s(input[name="args[duration_ms]"]))

    render_submit(view, "invoke_live_skill", %{
      "machine" => "watering_controller",
      "skill" => "configure_schedule",
      "args" => %{"interval_ms" => "120000", "duration_ms" => "30000"}
    })

    Process.sleep(50)

    html = render(view)

    assert html =~ "watering_controller :: skill configure_schedule"
    assert html =~ "reply=:ok"
    refute html =~ "{:invalid_schedule_value, :interval_ms}"
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

    Session.save_topology_source(
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
