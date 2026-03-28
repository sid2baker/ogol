defmodule Ogol.HMI.MachineStudioLiveTest do
  use Ogol.ConnCase, async: false

  test "renders machine studio through the shared Studio Cell shell" do
    {:ok, view, html} = live(build_conn(), "/studio/machines")

    assert html =~ "Machine Studio"
    assert html =~ "Studio Cell"
    assert html =~ "Build"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "Studio shell only"
    assert has_element?(view, "button", "Visual")
    assert has_element?(view, "button", "Build")
  end

  test "switches to source preview in place" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines")

    render_click(view, "set_editor_mode", %{"mode" => "source"})

    html = render(view)

    assert html =~ "machine :packaging_line do"
    assert html =~ "canonical machine source shape"
  end

  test "shows placeholder build banner instead of hiding the action" do
    {:ok, view, _html} = live(build_conn(), "/studio/machines")

    render_click(view, "build_machine", %{})

    html = render(view)

    assert html =~ "Build not wired yet"
    assert html =~ "machine build/apply kernel is the next slice"
  end
end
