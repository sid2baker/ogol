defmodule Ogol.StudioCellRoutingLiveTest do
  use Ogol.ConnCase, async: false

  test "machine section renders an index that links to full studio pages" do
    {:ok, view, html} = live(build_conn(), "/studio/machines")

    assert html =~ "Machines"
    assert has_element?(view, ~s(a[href="/studio/machines/packaging_line"]))
    assert has_element?(view, ~s(a[href="/studio/machines/inspection_cell"]))
  end

  test "machine full-page routes render the library and use the URL as the view source of truth" do
    {:ok, view, html} = live(build_conn(), "/studio/machines/packaging_line")

    assert html =~ "Packaging Line coordinator"
    assert html =~ "Select an available artifact to edit it in the Studio Cell."
    assert has_element?(view, ~s(a[href="/studio/machines/inspection_cell"]))

    render_click(view, "select_view", %{"view" => "source"})

    assert_patch(view, "/studio/machines/packaging_line/source")
    assert render(view) =~ "defmodule Ogol.Generated.Machines.PackagingLine do"
  end

  test "machine cell routes render only the selected body projection with no studio chrome" do
    {:ok, view, html} = live(build_conn(), "/studio/cells/machines/packaging_line/source")

    assert html =~ "defmodule Ogol.Generated.Machines.PackagingLine do"
    refute html =~ "Ogol Runtime"
    refute html =~ "Machine Studio"
    refute html =~ "Select an available artifact to edit it in the Studio Cell."
    refute has_element?(view, "[data-test='machine-view-config']")
    refute has_element?(view, ~s(a[href="/studio/machines/inspection_cell"]))
  end

  test "topology cell routes render only the selected body projection" do
    {:ok, view, html} = live(build_conn(), "/studio/cells/topology/visual")

    assert html =~ "Module Name"
    refute html =~ "Ogol Runtime"
    refute html =~ "Topology Studio"
    refute html =~ "Select an available artifact to edit it in the Studio Cell."
    refute has_element?(view, "[data-test='topology-view-visual']")
  end
end
