defmodule Ogol.HMI.StudioIndexLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Bundle
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore
  alias Ogol.Studio.DriverDraftStore.Draft
  alias Ogol.Studio.RevisionStore

  test "renders the studio home shell and artifact cards" do
    {:ok, _view, html} = live(build_conn(), "/studio")

    assert html =~ "Studio Contract"
    assert html =~ "Visual editors are projections over canonical source"
    assert html =~ "Studio Bundle"
    assert html =~ "Deploy Revision"
    assert html =~ "Export Bundle"
    assert html =~ "Open Bundle"
    assert html =~ "Examples"
    assert html =~ "HMIs"
    assert html =~ "Simulator"
    assert html =~ "EtherCAT"
    assert html =~ "Topology"
    assert html =~ "Sequences"
    assert html =~ "Machines"
    assert html =~ "Drivers"
    assert html =~ "Visual"
    assert html =~ "Source-only"
  end

  test "deploys a whole studio revision from Studio home" do
    {:ok, view, _html} = live(build_conn(), "/studio")

    render_click(view, "deploy_revision")

    html = render(view)

    assert html =~ "Revision deployed"
    assert html =~ "r1"
    assert [%RevisionStore.Revision{id: "r1"}] = RevisionStore.list_revisions()
  end

  test "opens a global studio bundle as the current draft bundle" do
    model =
      DriverDefinition.default_model("feeder_outputs")
      |> Map.put(:label, "Feeder Outputs")

    source =
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(model.module_name),
        model
      )

    DriverDraftStore.replace_drafts([
      %Draft{
        id: "feeder_outputs",
        source: source,
        model: model,
        sync_state: :synced,
        sync_diagnostics: []
      }
    ])

    {:ok, bundle_source} = Bundle.export_current(app_id: "packaging_line", revision: "r12")

    :ok = DriverDraftStore.reset()

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
    assert DriverDraftStore.fetch("feeder_outputs").model.label == "Feeder Outputs"
    assert DriverDraftStore.fetch("packaging_outputs") == nil
  end
end
