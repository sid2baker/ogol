defmodule Ogol.HMI.StudioIndexLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Session.RevisionFile
  alias Ogol.Topology.Registry
  alias Ogol.Session
  alias Ogol.Session.Revisions

  test "renders the studio home shell and artifact cards" do
    {:ok, _view, html} = live(build_conn(), "/studio")

    assert html =~ "Studio Contract"
    assert html =~ "Visual editors are projections over canonical source"
    assert html =~ "Manage simulation and bring hardware up from the Studio hub"
    assert html =~ "Load checked-in revisions into the current workspace"
    assert html =~ "Revision File"
    assert html =~ "Deploy Revision"
    assert html =~ "Export Revision"
    assert html =~ "Open Revision"
    assert html =~ "Workspace Topology"
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

    render_change(view, "change_revision_settings", %{
      "revision" => %{"app_id" => "ogol"}
    })

    render_click(view, "deploy_revision")

    html = render(view)

    assert html =~ "Revision deployed"
    assert html =~ "r1"

    assert [
             %Revisions.Revision{
               id: "r1",
               topology_id: "packaging_line"
             }
           ] =
             Revisions.list_revisions("ogol")

    assert %{topology_scope: :packaging_line} = Registry.active_topology()
  end

  test "opens a revision file as the current workspace revision" do
    model =
      Session.fetch_hardware_config_model("ethercat")
      |> Map.put(:label, "Feeder Ring")

    Session.put_hardware_config(:ethercat, model)

    {:ok, revision_source} =
      RevisionFile.export_current(app_id: "packaging_line", revision: "r12")

    :ok = Session.reset_hardware_configs()

    {:ok, view, _html} = live(build_conn(), "/studio")

    render_click(view, "toggle_revision_import")

    upload =
      file_input(view, "#studio-revision-import-form", :revision_file, [
        %{name: "packaging_line.ogol.ex", content: revision_source, type: "text/plain"}
      ])

    assert render_upload(upload, "packaging_line.ogol.ex") =~ "packaging_line.ogol.ex"

    render_submit(element(view, "#studio-revision-import-form"))

    html = render(view)

    assert html =~ "Revision loaded"
    assert html =~ "Loaded"
    assert html =~ "packaging_line"
    assert html =~ "r12"
    assert Session.fetch_hardware_config("ethercat").model.label == "Feeder Ring"
  end
end
