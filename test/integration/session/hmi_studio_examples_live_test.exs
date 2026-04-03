defmodule Ogol.HMI.StudioExamplesLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Session

  @example_id "pump_skid_commissioning_bench"

  test "renders the examples section on home and loads the commissioning bench into the current workspace" do
    {:ok, view, html} = live(build_conn(), "/studio")

    assert html =~ "Load checked-in revisions into the current workspace"
    assert html =~ "Pump Skid Commissioning Bench"
    assert html =~ "Load Into Workspace"

    render_click(view, "load_example", %{"id" => @example_id})

    html = render(view)

    assert html =~ "Example loaded"
    assert html =~ "Loaded 8 artifact(s)"
    assert html =~ "Open Machine Studio"
    assert html =~ "Open Topology Studio"
    assert html =~ "Open Sequence Studio"

    assert Session.fetch_machine("packaging_line") == nil

    assert Session.fetch_machine("transfer_pump").source =~
             "defmodule Ogol.Generated.Machines.TransferPump"

    assert Session.fetch_topology("packaging_line") == nil

    assert Session.fetch_topology("pump_skid_bench").source =~
             "defmodule Ogol.Generated.Topologies.PumpSkidBench"

    assert hardware_draft = Session.fetch_hardware_config("ethercat")
    assert hardware_draft.source =~ "defmodule Ogol.Generated.Hardware.Config.EtherCAT"
    assert hardware_draft.source =~ "ch1: :supply_valve_open_cmd"
    assert hardware_draft.source =~ "ch6: :horn_cmd"

    {:ok, _machine_view, machine_html} =
      live(build_conn(), "/studio/machines/transfer_pump")

    assert machine_html =~ "Transfer pump starter with wired running feedback"

    refute machine_html =~ "Packaging Line coordinator"
    refute machine_html =~ "Parse the machine into the supported model to render the graph here."
    assert machine_html =~ ~s(phx-hook="MermaidDiagram")
    assert machine_html =~ "Config Projection"
    assert machine_html =~ "Source uses features outside the first editor"

    {:ok, _topology_view, topology_html} = live(build_conn(), "/studio/topology")
    assert topology_html =~ "Pump skid commissioning topology"
    refute topology_html =~ "Packaging Line topology"

    assert Session.fetch_simulator_config("ethercat").source =~
             "defmodule Ogol.Generated.Simulator.Config.EtherCAT"

    {:ok, _sequence_view, sequence_html} =
      live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    assert sequence_html =~ "Commissioning cycle over a real EtherCAT loopback bench"
    assert sequence_html =~ "Available Machines"
    assert sequence_html =~ "supply_valve"
    assert sequence_html =~ "return_valve"
    assert sequence_html =~ "transfer_pump"
    assert sequence_html =~ "alarm_stack"
    assert sequence_html =~ "open"
    assert sequence_html =~ "running_fb?"
    assert sequence_html =~ "running_indicated"
  end
end
