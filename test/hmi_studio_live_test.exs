defmodule Ogol.HMI.HmiStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.{SurfaceDeploymentStore, SurfaceDraftStore}

  setup do
    SurfaceDraftStore.reset()
    SurfaceDeploymentStore.reset()
    :ok
  end

  test "renders the HMI Studio workspace for the default surface" do
    {:ok, _view, html} = live(build_conn(), "/studio/hmis")

    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "Save Draft"
    assert html =~ "Compile"
    assert html =~ "Deploy"
    assert html =~ "Assign Panel"
    assert html =~ "Compiled runtime surface"
    assert html =~ "panel_1280x800"
    assert html =~ "panel_1920x1080"
    assert html =~ "Operations Triage"
  end

  test "compiled surfaces affect runtime only after panel assignment" do
    {:ok, view, _html} = live(build_conn(), "/studio/hmis")

    render_change(view, "change_metadata", %{
      "surface" => %{
        "title" => "Studio Runtime Title",
        "summary" => "Studio-edited operator surface summary."
      }
    })

    assert render(view) =~ "Studio Runtime Title"

    render_click(view, "compile_draft")
    render_click(view, "deploy_draft")

    {:ok, _runtime_view, runtime_html_before} = live(build_conn(), "/ops")

    refute runtime_html_before =~ "Studio Runtime Title"
    assert runtime_html_before =~ "Operations Triage"

    render_click(view, "assign_panel")

    {:ok, _runtime_view, runtime_html_after} = live(build_conn(), "/ops")

    assert runtime_html_after =~ "Studio Runtime Title"
    assert runtime_html_after =~ "r1"
  end

  test "visual zone configuration updates the compiled runtime surface" do
    {:ok, view, _html} = live(build_conn(), "/studio/hmis")

    render_change(view, "change_zone_config", %{
      "zones" => %{
        "status_rail" => %{
          "type" => "status_tile",
          "binding" => "runtime_summary",
          "label" => "Healthy Units",
          "field" => "active"
        }
      }
    })

    assert render(view) =~ "Healthy Units"

    render_click(view, "compile_draft")
    render_click(view, "deploy_draft")
    render_click(view, "assign_panel")

    {:ok, _runtime_view, runtime_html} = live(build_conn(), "/ops")

    assert runtime_html =~ "Healthy Units"
  end

  test "assigning a different surface changes the runtime player" do
    {:ok, view, html} = live(build_conn(), "/studio/hmis/operations_alarm_focus")

    assert html =~ "Alarm Focus"

    render_click(view, "assign_panel")

    {:ok, _runtime_view, runtime_html} = live(build_conn(), "/ops")

    assert runtime_html =~ "Alarm Focus"
    assert runtime_html =~ "Healthy Units"
  end

  test "panel assignment can stay on an older published version until reassigned" do
    {:ok, view, _html} = live(build_conn(), "/studio/hmis")

    render_change(view, "change_metadata", %{
      "surface" => %{
        "title" => "Runtime Version One",
        "summary" => "First published overview surface."
      }
    })

    render_click(view, "compile_draft")
    render_click(view, "deploy_draft")
    render_click(view, "assign_panel")

    {:ok, _runtime_view, runtime_html_v1} = live(build_conn(), "/ops")
    assert runtime_html_v1 =~ "Runtime Version One"
    assert runtime_html_v1 =~ "r1"

    render_change(view, "change_metadata", %{
      "surface" => %{
        "title" => "Runtime Version Two",
        "summary" => "Second published overview surface."
      }
    })

    render_click(view, "compile_draft")
    render_click(view, "deploy_draft")

    {:ok, _runtime_view, runtime_html_still_v1} = live(build_conn(), "/ops")
    assert runtime_html_still_v1 =~ "Runtime Version One"
    refute runtime_html_still_v1 =~ "Runtime Version Two"
    assert runtime_html_still_v1 =~ "r1"

    render_change(view, "select_assignment_version", %{"assignment" => %{"version" => "r2"}})
    render_click(view, "assign_panel")

    {:ok, _runtime_view, runtime_html_v2} = live(build_conn(), "/ops")
    assert runtime_html_v2 =~ "Runtime Version Two"
    assert runtime_html_v2 =~ "r2"
  end
end
