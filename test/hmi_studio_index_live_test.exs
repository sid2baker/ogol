defmodule Ogol.HMI.StudioIndexLiveTest do
  use Ogol.ConnCase, async: false

  test "renders the studio home shell and artifact cards" do
    {:ok, _view, html} = live(build_conn(), "/studio")

    assert html =~ "Studio Contract"
    assert html =~ "Visual editors are projections over canonical DSL"
    assert html =~ "HMIs"
    assert html =~ "Hardware"
    assert html =~ "Topology"
    assert html =~ "Machines"
    assert html =~ "Drivers"
    assert html =~ "Visual"
    assert html =~ "DSL-only"
  end
end
