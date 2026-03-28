defmodule Ogol.HMI.StudioIndexLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Bundle
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore

  test "renders the studio home shell and artifact cards" do
    {:ok, _view, html} = live(build_conn(), "/studio")

    assert html =~ "Studio Contract"
    assert html =~ "Visual editors are projections over canonical DSL"
    assert html =~ "Studio Bundle"
    assert html =~ "Export Bundle"
    assert html =~ "Open Bundle"
    assert html =~ "HMIs"
    assert html =~ "Hardware"
    assert html =~ "Topology"
    assert html =~ "Machines"
    assert html =~ "Drivers"
    assert html =~ "Visual"
    assert html =~ "DSL-only"
  end

  test "imports a global studio bundle and follows workspace hints" do
    model =
      DriverDefinition.default_model("feeder_outputs")
      |> Map.put(:label, "Feeder Outputs")

    source =
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(model.module_name),
        model
      )

    DriverDraftStore.save_source("feeder_outputs", source, model, :synced, [])

    {:ok, bundle_source} =
      Bundle.export_current(
        app_id: "packaging_line",
        workspace: %{open_artifact: {:driver, "feeder_outputs"}, editor_mode: :source}
      )

    :ok = DriverDraftStore.reset()

    {:ok, view, _html} = live(build_conn(), "/studio")

    render_click(view, "toggle_bundle_import")

    upload =
      file_input(view, "#studio-bundle-import-form", :bundle, [
        %{name: "packaging_line.ogol.ex", content: bundle_source, type: "text/plain"}
      ])

    assert render_upload(upload, "packaging_line.ogol.ex") =~ "packaging_line.ogol.ex"

    render_submit(element(view, "#studio-bundle-import-form"))

    assert_redirected(view, "/studio/drivers/feeder_outputs")
  end
end
