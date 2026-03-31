defmodule Ogol.HMI.SurfaceLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Examples.SimpleHmiDemo
  alias Ogol.HMI.{SurfaceDeployment, SurfaceDeploymentStore, SurfaceRuntimeStore}
  alias Ogol.TestSupport.SlowRequestMachine
  alias Ogol.TestSupport.SampleMachine
  alias Ogol.HMIWeb.Layouts

  setup do
    SurfaceRuntimeStore.reset()
    SurfaceDeploymentStore.reset()
    :ok
  end

  test "renders the assigned runtime surface with machine snapshots and recent events" do
    {:ok, view, html} = live(build_conn(), "/ops")
    assert html =~ "Operations Triage"
    assert html =~ "Ogol Runtime Surface"
    assert html =~ "primary_runtime_panel"

    {:ok, pid} = SampleMachine.start_link()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "sample_machine"
      assert rendered =~ "idle"
      assert rendered =~ "Controls"
    end)

    view
    |> element("[data-test='control-sample_machine-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "started"
      assert rendered =~ "machine started"
      assert rendered =~ "state entered"
      assert rendered =~ "operator skill invoked"
    end)
  end

  test "renders the fallback surface launcher and direct runtime route" do
    assignment = SurfaceDeployment.default_assignment()

    {:ok, _view, html} = live(build_conn(), "/ops/hmis")

    assert html =~ "Runtime Surfaces"
    assert html =~ to_string(assignment.surface_id)
    assert html =~ to_string(assignment.panel_id)

    {:ok, _view, direct_html} =
      live(build_conn(), "/ops/hmis/#{assignment.surface_id}/#{assignment.default_screen}")

    assert direct_html =~ "Operations Triage"
    assert direct_html =~ "Ogol Runtime Surface"

    {:ok, _view, station_html} = live(build_conn(), "/ops/hmis/operations_station/station")

    assert station_html =~ "Station Panel"
  end

  test "dispatches request and event controls from the overview" do
    {:ok, view, _html} = live(build_conn(), "/ops")

    {:ok, pid} = SimpleHmiDemo.boot!()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simple_hmi_line"
      assert rendered =~ "start"
      assert rendered =~ "part seen"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "operator skill invoked"
      assert rendered =~ "reply=ok"
      assert rendered =~ "running"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-part_seen']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "operator skill invoked"
      assert rendered =~ "reply=accepted"
      assert rendered =~ "part_counted"
      assert rendered =~ "part_count"
    end)
  end

  test "operator request dispatch does not block the liveview while machine is busy" do
    {:ok, view, _html} = live(build_conn(), "/ops")

    {:ok, pid} = SlowRequestMachine.start_link()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "slow_request_machine"
      assert rendered =~ "start"
    end)

    view
    |> element("[data-test='control-slow_request_machine-skill-start']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "invoking skill"
    assert rendered =~ "slow_request_machine :: skill start"

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "reply=ok"
      assert rendered =~ "running"
      assert rendered =~ "operator skill invoked"
    end)
  end

  test "renders the runtime surface without app-shell navigation chrome" do
    {:ok, view, _html} = live(build_conn(), "/ops")

    refute has_element?(view, "aside")
    assert has_element?(view, "[data-test='surface-screen-overview']")
    refute render(view) =~ "Studio"
  end

  test "renders a station surface and dispatches focused machine skills" do
    {:ok, pid} = SimpleHmiDemo.boot!()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    SurfaceDeployment.assign_panel(:primary_runtime_panel, :operations_station)

    {:ok, view, html} = live(build_conn(), "/ops")

    assert html =~ "Station Panel"

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simple_hmi_line"
      assert rendered =~ "start"
      assert rendered =~ "part seen"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "operator skill invoked"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-part_seen']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "part_counted"
      assert rendered =~ "reply=accepted"
    end)
  end

  test "uses an accessible active mode tab treatment in the app header" do
    html =
      render_component(&Layouts.app/1, %{
        inner_content: "",
        hmi_mode: :ops,
        hmi_nav: :surfaces,
        page_title: "Operations",
        page_summary:
          "Triage-first runtime supervision for machines, hardware, and recent incidents."
      })

    assert html =~
             "bg-[var(--app-info-strong)] px-4 py-2 font-mono text-[11px] font-semibold uppercase tracking-[0.22em] text-[var(--app-shell)]"

    assert html =~ "aria-current=\"page\""
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError] ->
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
  end
end
