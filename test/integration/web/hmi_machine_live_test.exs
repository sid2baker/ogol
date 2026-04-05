defmodule Ogol.HMI.MachineLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Session
  alias Ogol.TestSupport.SimpleHmiDemo
  alias Ogol.TestSupport.SampleMachine

  test "renders the machine instance index grouped by module" do
    {:ok, primary_pid} = SampleMachine.start_link(machine_id: :primary_sample_machine)
    {:ok, backup_pid} = SampleMachine.start_link(machine_id: :backup_sample_machine)

    on_exit(fn ->
      Enum.each([primary_pid, backup_pid], fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      end)
    end)

    {:ok, view, _html} = live(build_conn(), "/ops/machines")

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Machine Instances"
      assert rendered =~ "primary_sample_machine"
      assert rendered =~ "backup_sample_machine"
      assert rendered =~ "Ogol.TestSupport.SampleMachine"
      assert has_element?(view, "[data-test='machine-group-ogol-testsupport-samplemachine']")
      assert has_element?(view, "[data-test='machine-open-detail-primary_sample_machine']")
      assert has_element?(view, "[data-test='ops-control-strip']")
    end)
  end

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
      assert rendered =~ "Derived live machine graph"
      assert rendered =~ "Public Interface"
      assert rendered =~ "part_count"
      assert rendered =~ "running?"
      assert rendered =~ "enabled?"
      assert rendered =~ "Open detail"
      assert has_element?(view, "[data-test='machine-instance-diagram']")
      assert has_element?(view, "[data-test='ops-control-strip']")
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

    assert html =~ "Machine instance unavailable"
    assert html =~ "Machine Instances"
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

  test "shows sibling instances and global control switching on machine pages" do
    {:ok, primary_pid} = SimpleHmiDemo.LineMachine.start_link(machine_id: :filler_a)
    {:ok, backup_pid} = SimpleHmiDemo.LineMachine.start_link(machine_id: :filler_b)

    on_exit(fn ->
      Enum.each([primary_pid, backup_pid], fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :shutdown)
      end)
    end)

    {:ok, index_view, _html} = live(build_conn(), "/ops/machines")

    index_view
    |> element("[data-test='ops-control-arm-auto']")
    |> render_click()

    assert_eventually(fn ->
      assert Session.control_mode() == :auto
      assert render(index_view) =~ "Auto"
    end)

    {:ok, detail_view, _html} = live(build_conn(), "/ops/machines/filler_a")

    assert_eventually(fn ->
      rendered = render(detail_view)
      assert rendered =~ "filler_b"
      assert has_element?(detail_view, "[data-test='ops-control-switch-to-manual']")
      assert has_element?(detail_view, "[data-test='machine-instance-diagram']")
    end)

    detail_view
    |> element("[data-test='ops-control-switch-to-manual']")
    |> render_click()

    assert_eventually(fn ->
      assert Session.control_mode() == :manual
      assert render(detail_view) =~ "Manual"
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
