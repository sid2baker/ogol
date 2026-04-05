defmodule Ogol.HMI.MachineLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Session
  alias Ogol.TestSupport.SimpleHmiDemo

  test "renders machine detail and supports operator controls" do
    {:ok, pid} = SimpleHmiDemo.boot!()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    {:ok, view, _html} = live(build_conn(), "/ops/machines/simple_hmi_line")

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simple_hmi_line"
      assert rendered =~ "Tiny in-memory line machine for the LiveView HMI"
      assert rendered =~ "Public Interface"
      assert rendered =~ "part_count"
      assert rendered =~ "running?"
      assert rendered =~ "enabled?"
      assert rendered =~ "Open detail"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "operator skill invoked"
      assert rendered =~ "reply=ok"
      assert rendered =~ "running"
      assert rendered =~ "started"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-part_seen']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "operator skill invoked"
      assert rendered =~ "reply=accepted"
      assert rendered =~ "part_counted"
      assert rendered =~ ">1<"
    end)
  end

  test "shows unavailable state for unknown machines" do
    {:ok, _view, html} = live(build_conn(), "/ops/machines/missing_machine")

    assert html =~ "Machine unavailable"
    assert html =~ "Operations"
  end

  test "denies operator controls while Auto is armed" do
    {:ok, pid} = SimpleHmiDemo.boot!()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    {:ok, view, _html} = live(build_conn(), "/ops/machines/simple_hmi_line")

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='control-simple_hmi_line-skill-start']")
    end)

    assert :ok = Session.set_control_mode(:auto)

    view
    |> element("[data-test='control-simple_hmi_line-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simple_hmi_line :: skill start"
      assert rendered =~ "reason=auto_mode_armed"
      refute rendered =~ "reply=ok"
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
