defmodule Ogol.HMI.StudioExamplesLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.WorkspaceStore

  test "renders the examples section on home and loads the watering example revision into the current workspace" do
    {:ok, view, html} = live(build_conn(), "/studio")

    assert html =~ "Load checked-in revisions into the current workspace"
    assert html =~ "Watering Valves"
    assert html =~ "Sequence Starter Cell"
    assert html =~ "Load Into Workspace"

    render_click(view, "load_example", %{"id" => "watering_valves"})

    html = render(view)

    assert html =~ "Example loaded"
    assert html =~ "Loaded 2 artifact(s)"
    assert html =~ "Open Machine Studio"
    assert html =~ "Open Topology Studio"

    assert WorkspaceStore.fetch_machine("packaging_line") == nil

    assert WorkspaceStore.fetch_machine("watering_controller").source =~
             "defmodule Ogol.Generated.Machines.WateringController"

    assert WorkspaceStore.fetch_topology("packaging_line") == nil

    assert WorkspaceStore.fetch_topology("watering_system").source =~
             "defmodule Ogol.Generated.Topologies.WateringSystem"

    {:ok, _machine_view, machine_html} = live(build_conn(), "/studio/machines")

    assert machine_html =~
             "Four-zone watering controller with rotating schedule and manual override"

    refute machine_html =~ "Packaging Line coordinator"
    refute machine_html =~ "Parse the machine into the supported model to render the graph here."
    assert machine_html =~ "State Graph"
    assert machine_html =~ "Config Projection"
    assert machine_html =~ "Source uses features outside the first editor"

    {:ok, _topology_view, topology_html} = live(build_conn(), "/studio/topology")
    assert topology_html =~ "Four-zone watering system topology"
    refute topology_html =~ "Packaging Line topology"
  end

  test "loads the sequence starter example revision and exposes it in sequence studio" do
    {:ok, view, _html} = live(build_conn(), "/studio")

    render_click(view, "load_example", %{"id" => "sequence_starter_cell"})

    html = render(view)

    assert html =~ "Example loaded"
    assert html =~ "Loaded 5 artifact(s)"
    assert html =~ "Open Machine Studio"
    assert html =~ "Open Topology Studio"
    assert html =~ "Open Sequence Studio"

    assert WorkspaceStore.fetch_machine("packaging_line") == nil

    assert WorkspaceStore.fetch_machine("feeder").source =~
             "defmodule Ogol.Generated.Machines.Feeder"

    assert WorkspaceStore.fetch_machine("clamp").source =~
             "defmodule Ogol.Generated.Machines.Clamp"

    assert WorkspaceStore.fetch_machine("inspector").source =~
             "defmodule Ogol.Generated.Machines.Inspector"

    assert WorkspaceStore.fetch_sequence("sequence_starter_auto").source =~
             "defmodule Ogol.Generated.Sequences.SequenceStarterAuto"

    assert WorkspaceStore.fetch_topology("sequence_starter_cell").source =~
             "defmodule Ogol.Generated.Topologies.SequenceStarterCell"

    {:ok, _sequence_view, sequence_html} =
      live(build_conn(), "/studio/sequences/sequence_starter_auto")

    assert sequence_html =~ "Starter sequence over feeder, clamp, and inspector contracts"
    assert sequence_html =~ "Available Machines"
    assert sequence_html =~ "feeder"
    assert sequence_html =~ "clamp"
    assert sequence_html =~ "inspector"
    assert sequence_html =~ "feed_part"
    assert sequence_html =~ "closed?"
    assert sequence_html =~ "passed?"
  end
end
