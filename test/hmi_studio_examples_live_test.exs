defmodule Ogol.HMI.StudioExamplesLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.MachineDraftStore
  alias Ogol.Studio.TopologyDraftStore

  test "renders the examples page and loads the watering example bundle as the current draft bundle" do
    {:ok, view, html} = live(build_conn(), "/studio/examples")

    assert html =~ "Load checked-in revision bundles as the current draft"
    assert html =~ "Watering Valves"
    assert html =~ "Load Into Draft"

    render_click(view, "load_example", %{"id" => "watering_valves"})

    html = render(view)

    assert html =~ "Example loaded"
    assert html =~ "Loaded 2 artifact(s)"
    assert html =~ "Open Machine Studio"
    assert html =~ "Open Topology Studio"

    assert MachineDraftStore.fetch("packaging_line") == nil

    assert MachineDraftStore.fetch("watering_controller").source =~
             "defmodule Ogol.Generated.Machines.WateringController"

    assert TopologyDraftStore.fetch("packaging_line") == nil

    assert TopologyDraftStore.fetch("watering_system").source =~
             "defmodule Ogol.Generated.Topologies.WateringSystem"

    {:ok, _machine_view, machine_html} = live(build_conn(), "/studio/machines")

    assert machine_html =~
             "Four-zone watering controller with rotating schedule and manual override"

    refute machine_html =~ "Packaging Line coordinator"

    {:ok, _topology_view, topology_html} = live(build_conn(), "/studio/topology")
    assert topology_html =~ "Four-zone watering system topology"
    refute topology_html =~ "Packaging Line topology"
  end
end
