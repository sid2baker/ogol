defmodule Ogol.HMI.StudioIndexLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.HardwareGateway
  alias Ogol.Studio.Bundle
  alias Ogol.Driver.Source, as: DriverSource
  alias Ogol.Topology.Registry
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.WorkspaceStore.DriverDraft
  alias Ogol.Studio.RevisionStore

  test "renders the studio home shell and artifact cards" do
    {:ok, _view, html} = live(build_conn(), "/studio")

    assert html =~ "Studio Contract"
    assert html =~ "Visual editors are projections over canonical source"
    assert html =~ "Start simulation and hardware work from the Studio hub"
    assert html =~ "Load checked-in revision bundles as the current draft"
    assert html =~ "Studio Bundle"
    assert html =~ "Deploy Revision"
    assert html =~ "Export Bundle"
    assert html =~ "Open Bundle"
    assert html =~ "Deploy Topology"
    refute html =~ "Hardware Config"
    assert html =~ "HMIs"
    assert html =~ "Sequences"
    assert html =~ "Topology"
    assert html =~ "Machines"
    assert html =~ "Hardware"
    assert html =~ "Simulator"
    assert html =~ "Hardware Startup"
    assert html =~ "Watering Valves"
    assert html =~ "Sequence Starter Cell"
    assert html =~ "Visual"
    assert html =~ "Source-only"
  end

  test "deploys a whole studio revision from Studio home" do
    {:ok, view, _html} = live(build_conn(), "/studio")

    render_click(view, "deploy_revision")

    html = render(view)

    assert html =~ "Revision deployed"
    assert html =~ "r1"

    assert [
             %RevisionStore.Revision{
               id: "r1",
               topology_id: "packaging_line",
               hardware_config_id: "ethercat_demo"
             }
           ] =
             RevisionStore.list_revisions()

    assert %{root: :packaging_line} = Registry.active_topology()
    assert HardwareGateway.ethercat_master_running?()
  end

  test "opens a global studio bundle as the current draft bundle" do
    model =
      DriverSource.default_model("feeder_outputs")
      |> Map.put(:label, "Feeder Outputs")

    source =
      DriverSource.to_source(
        DriverSource.module_from_name!(model.module_name),
        model
      )

    WorkspaceStore.replace_drivers([
      %DriverDraft{
        id: "feeder_outputs",
        source: source,
        model: model,
        sync_state: :synced,
        sync_diagnostics: []
      }
    ])

    {:ok, bundle_source} = Bundle.export_current(app_id: "packaging_line", revision: "r12")

    :ok = WorkspaceStore.reset_drivers()

    {:ok, view, _html} = live(build_conn(), "/studio")

    render_click(view, "toggle_bundle_import")

    upload =
      file_input(view, "#studio-bundle-import-form", :bundle, [
        %{name: "packaging_line.ogol.ex", content: bundle_source, type: "text/plain"}
      ])

    assert render_upload(upload, "packaging_line.ogol.ex") =~ "packaging_line.ogol.ex"

    render_submit(element(view, "#studio-bundle-import-form"))

    html = render(view)

    assert html =~ "Bundle loaded"
    assert html =~ "Loaded"
    assert html =~ "packaging_line"
    assert html =~ "r12"
    assert WorkspaceStore.fetch_driver("feeder_outputs").model.label == "Feeder Outputs"
    assert WorkspaceStore.fetch_driver("packaging_outputs") == nil
  end
end
