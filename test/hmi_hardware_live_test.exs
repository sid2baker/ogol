defmodule Ogol.HMI.EthercatLiveTest do
  use Ogol.ConnCase, async: false

  alias EtherCAT.Master
  alias Ogol.TestSupport.EthercatHmiFixture

  setup do
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      EthercatHmiFixture.stop_all!()
    end)

    :ok
  end

  test "renders the ethercat page with the master cell first" do
    {:ok, view, html} = live(build_conn(), "/studio/ethercat")

    {master_pos, _} = :binary.match(html, "data-test=\"hardware-section-master\"")
    {status_pos, _} = :binary.match(html, "data-test=\"hardware-section-bus-watch\"")

    assert html =~ "EtherCAT Studio"
    assert has_element?(view, "[data-test='hardware-section-master']")
    assert has_element?(view, "[data-test='master-scan']")
    assert has_element?(view, "[data-test='start-master']")
    assert master_pos < status_pos
    refute html =~ "Draft / Test"
    refute html =~ "Armed Gate"
  end

  test "master cell can toggle between visual and source views" do
    {:ok, view, _html} = live(build_conn(), "/studio/ethercat")

    refute has_element?(view, "[data-test='master-cell-source']")

    view
    |> element("[data-test='hardware-cell-mode-master-source']")
    |> render_click()

    rendered = render(view)

    assert has_element?(view, "[data-test='master-cell-source']")
    assert rendered =~ "master_cell do"
    assert rendered =~ "watch_slave :coupler"
  end

  test "captures a runtime snapshot from the diagnostics section" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/ethercat")

    view
    |> element("[data-test='capture-runtime-snapshot']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Runtime Snapshot captured"
    assert rendered =~ "Saved Snapshots"
    assert rendered =~ "Runtime Snapshot"
    assert rendered =~ "Selected Snapshot"
    assert rendered =~ "Recent Events"
    assert rendered =~ "Download JSON"
  end

  test "simulator-backed ethercat sessions keep the master card first and bus watch second" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/ethercat")

    assert_eventually(fn ->
      rendered = render(view)
      {master_pos, _} = :binary.match(rendered, "data-test=\"hardware-section-master\"")
      {status_pos, _} = :binary.match(rendered, "data-test=\"hardware-section-bus-watch\"")

      assert rendered =~ "Simulated"
      assert rendered =~ "Current master state"
      assert has_element?(view, "[data-test='master-scan']")
      assert has_element?(view, "[data-test='stop-master']")
      assert master_pos < status_pos
      refute rendered =~ "Draft / Test"
      refute rendered =~ "Candidate vs Armed"
      refute rendered =~ "Capture / Baseline"
      refute rendered =~ "Provisioning"
    end)
  end

  test "scan updates the master card from the current bus" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/ethercat")

    view
    |> element("[data-test='master-scan']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "master scan synced from live bus"
      assert rendered =~ "watched 3 slave(s)"
      assert rendered =~ "coupler (EtherCAT.Driver.EK1100)"
      assert rendered =~ "inputs (EtherCAT.Driver.EL1809)"
      assert rendered =~ "outputs (EtherCAT.Driver.EL2809)"
    end)
  end

  test "the ethercat page can stop and restart the master against the running simulator" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/ethercat")

    view
    |> element("[data-test='stop-master']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "EtherCAT master stopped"

      assert match?(
               %Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle],
               Master.status()
             )

      assert has_element?(view, "[data-test='start-master']")
    end)

    view
    |> element("[data-test='start-master']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "EtherCAT master started"
      assert rendered =~ "preop_ready"
      assert %Master.Status{lifecycle: :preop_ready} = Master.status()
      assert has_element?(view, "[data-test='stop-master']")
    end)
  end

  defp assert_eventually(fun, attempts \\ 30)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError] ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end
end
