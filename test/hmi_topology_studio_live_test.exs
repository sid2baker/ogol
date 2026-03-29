defmodule Ogol.HMI.TopologyStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.MachineDefinition
  alias Ogol.Studio.MachineDraftStore
  alias Ogol.Studio.RevisionStore
  alias Ogol.Studio.TopologyDraftStore
  alias Ogol.Studio.TopologyRuntime
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

  test "shows the currently active topology when one is running" do
    boot_ethercat_master!()

    draft = TopologyDraftStore.fetch("pack_and_inspect_cell")

    assert {:ok, _result} =
             TopologyRuntime.start("pack_and_inspect_cell", draft.source, draft.model)

    {:ok, _view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Pack and inspect cell topology"
    assert html =~ "infeed_conveyor"
    assert html =~ "inspection_station"
    assert html =~ "dependency_down"
  end

  test "revision query loads topology from the selected snapshot instead of the active runtime" do
    revision_model =
      TopologyDraftStore.fetch("packaging_line").model
      |> Map.put(:meaning, "Packaging Line Revision Topology")

    TopologyDraftStore.save_source(
      "packaging_line",
      Ogol.Studio.TopologyDefinition.to_source(revision_model),
      revision_model,
      :synced,
      []
    )

    assert {:ok, %RevisionStore.Revision{id: "r1"}} =
             RevisionStore.deploy_current(app_id: "ogol_bundle")

    draft_model =
      TopologyDraftStore.fetch("packaging_line").model
      |> Map.put(:meaning, "Packaging Line Draft Topology")

    TopologyDraftStore.save_source(
      "packaging_line",
      Ogol.Studio.TopologyDefinition.to_source(draft_model),
      draft_model,
      :synced,
      []
    )

    boot_ethercat_master!()

    active_draft = TopologyDraftStore.fetch("pack_and_inspect_cell")

    assert {:ok, _result} =
             TopologyRuntime.start(
               "pack_and_inspect_cell",
               active_draft.source,
               active_draft.model
             )

    {:ok, _view, html} = live(build_conn(), "/studio/topology?revision=r1")

    assert html =~ "Packaging Line Revision Topology"
    refute html =~ "Pack and inspect cell topology"

    assert TopologyDraftStore.fetch("packaging_line").model.meaning ==
             "Packaging Line Draft Topology"
  end

  test "machine module selection lists available machine drafts" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    html = render(view)

    assert html =~ ~s(select name="topology[machines][0][module_name]")
    assert html =~ ~s(value="Ogol.Generated.Machines.PackagingLine")
    assert html =~ ~s(value="Ogol.Generated.Machines.InspectionCell")
    assert html =~ "Inspection cell coordinator (inspection_cell)"
  end

  test "adds a new machine draft to the selected topology from the visual editor" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_click(view, "add_topology_machine", %{})

    assert MachineDraftStore.fetch("machine_1")
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

    render_click(view, "request_transition", %{"transition" => "start"})

    html = render(view)

    assert html =~ "Stop"
    assert html =~ "Running"
    assert %{root: :packaging_line} = Ogol.Topology.Registry.active_topology()

    render_click(view, "request_transition", %{"transition" => "stop"})

    html = render(view)

    assert html =~ "Start"
    refute html =~ "Stop"
    assert Ogol.Topology.Registry.active_topology() == nil
  end

  test "start surfaces invalid observation dependencies without compiling the topology" do
    boot_ethercat_master!()

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_change(view, "change_visual", %{
      "topology" => %{
        "topology_id" => "packaging_line",
        "module_name" => "Ogol.Generated.Topologies.PackagingLineInvalidObservation",
        "root_machine" => "packaging_line",
        "strategy" => "one_for_one",
        "meaning" => "Packaging line runtime topology",
        "machine_count" => "2",
        "observation_count" => "1",
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
        },
        "observations" => %{
          "0" => %{
            "kind" => "signal",
            "source" => "inspection_cell",
            "item" => "faulted",
            "as" => "inspection_faulted",
            "meaning" => "Inspection fault forwarded"
          }
        }
      }
    })

    render_click(view, "request_transition", %{"transition" => "start"})

    html = render(view)

    assert html =~ "Start failed"

    assert html =~
             "Observation source inspection_cell is not a declared dependency of root packaging_line."

    assert html =~ "Start"
    assert Ogol.Topology.Registry.active_topology() == nil
  end

  test "start succeeds once the root machine declares the dependency and event" do
    boot_ethercat_master!()

    machine_model =
      MachineDefinition.default_model("packaging_line")
      |> Map.put(:events, [%{name: "inspection_faulted", meaning: "Inspection forwarded"}])
      |> Map.put(:dependencies, [
        %{
          name: "inspection_cell",
          meaning: "Inspection dependency",
          skills: [],
          signals: ["faulted"],
          status: []
        }
      ])

    MachineDraftStore.save_source(
      "packaging_line",
      MachineDefinition.to_source(machine_model),
      machine_model,
      :synced,
      []
    )

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_change(view, "change_visual", %{
      "topology" => %{
        "topology_id" => "packaging_line",
        "module_name" => "Ogol.Generated.Topologies.PackagingLineWithInspection",
        "root_machine" => "packaging_line",
        "strategy" => "one_for_one",
        "meaning" => "Packaging line runtime topology",
        "machine_count" => "2",
        "observation_count" => "1",
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
        },
        "observations" => %{
          "0" => %{
            "kind" => "signal",
            "source" => "inspection_cell",
            "item" => "faulted",
            "as" => "inspection_faulted",
            "meaning" => "Inspection fault forwarded"
          }
        }
      }
    })

    render_click(view, "request_transition", %{"transition" => "start"})

    html = render(view)

    assert html =~ "Running"
    assert %{root: :packaging_line} = Ogol.Topology.Registry.active_topology()
  end

  test "start surfaces machine dependencies that are missing from the topology" do
    boot_ethercat_master!()

    machine_model =
      MachineDefinition.default_model("packaging_line")
      |> Map.put(:dependencies, [
        %{
          name: "inspection_cell",
          meaning: "Inspection dependency",
          skills: [],
          signals: [],
          status: []
        }
      ])

    MachineDraftStore.save_source(
      "packaging_line",
      MachineDefinition.to_source(machine_model),
      machine_model,
      :synced,
      []
    )

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_change(view, "change_visual", %{
      "topology" => %{
        "topology_id" => "packaging_line",
        "module_name" => "Ogol.Generated.Topologies.PackagingLineMissingDependency",
        "root_machine" => "packaging_line",
        "strategy" => "one_for_one",
        "meaning" => "Packaging line runtime topology",
        "machine_count" => "1",
        "observation_count" => "0",
        "machines" => %{
          "0" => %{
            "name" => "packaging_line",
            "module_name" => "Ogol.Generated.Machines.PackagingLine",
            "restart" => "permanent",
            "meaning" => "Packaging line coordinator"
          }
        },
        "observations" => %{}
      }
    })

    render_click(view, "request_transition", %{"transition" => "start"})

    html = render(view)

    assert html =~ "Start failed"

    assert html =~
             "Machine packaging_line declares dependency inspection_cell but the topology does not declare that machine."

    assert Ogol.Topology.Registry.active_topology() == nil
  end

  test "start is blocked until the ethercat master is running" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_click(view, "request_transition", %{"transition" => "start"})

    html = render(view)

    assert html =~ "Start blocked"
    assert html =~ "Start the EtherCAT master before starting this topology."
    assert Ogol.Topology.Registry.active_topology() == nil
  end

  test "falls back to source mode when the topology source leaves the supported subset" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    unsupported_source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology
      alias Custom.Helper

      topology do
        root(:packaging_line)
      end

      machines do
        machine(:packaging_line, Ogol.Generated.Machines.PackagingLine)
      end
    end
    """

    render_change(view, "change_source", %{"draft" => %{"source" => unsupported_source}})

    html = render(view)

    assert html =~ "Visual editor unavailable"
    assert html =~ "unsupported top-level constructs"
    assert html =~ "alias Custom.Helper"
  end

  test "loads persisted parser diagnostics without crashing the topology page" do
    bad_source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology

      topology do
        root(:packaging_line)
    end
    """

    TopologyDraftStore.save_source(
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
        "root_machine" => "packaging_line",
        "strategy" => "one_for_all",
        "meaning" => "Packaging line runtime topology",
        "machine_count" => "2",
        "observation_count" => "1",
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
        },
        "observations" => %{
          "0" => %{
            "kind" => "signal",
            "source" => "inspection_cell",
            "item" => "faulted",
            "as" => "inspection_faulted",
            "meaning" => "Inspection fault forwarded"
          }
        }
      }
    })

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    assert html =~ "Packaging line runtime topology"
    assert html =~ "strategy(:one_for_all)"
    assert html =~ "observe_signal(:inspection_cell, :faulted"
  end

  defp boot_ethercat_master! do
    EthercatHmiFixture.boot_preop_ring!()
  end
end
