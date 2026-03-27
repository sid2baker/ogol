defmodule Ogol.HMI.OverviewLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Examples.SimpleHmiDemo
  alias Ogol.TestSupport.SlowRequestMachine
  alias Ogol.TestSupport.SampleMachine

  test "renders machine snapshots and recent events" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Operations Overview"

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

  test "dispatches request and event controls from the overview" do
    {:ok, view, _html} = live(build_conn(), "/")

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
    {:ok, view, _html} = live(build_conn(), "/")

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
