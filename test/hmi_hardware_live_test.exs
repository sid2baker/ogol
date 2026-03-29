defmodule Ogol.HMI.EthercatLiveTest do
  use Ogol.ConnCase, async: false

  alias EtherCAT.Master
  alias Ogol.HMI.HardwareGateway
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
    assert has_element?(view, "[data-test='master-config-form']")

    view
    |> element("[data-test='hardware-cell-mode-master-source']")
    |> render_click()

    rendered = render(view)

    assert has_element?(view, "[data-test='master-cell-source']")
    assert rendered =~ "master_cell do"
    assert rendered =~ "watch_slave :coupler"
  end

  test "master visual form lets you edit watched slaves directly" do
    {:ok, view, _html} = live(build_conn(), "/studio/ethercat")

    assert has_element?(view, "[data-test='master-watched-slaves']")
    assert has_element?(view, "[data-test='master-slave-row-0']")
    assert has_element?(view, "select[name='simulation_config[slaves][0][driver]']")

    assert has_element?(
             view,
             "select[name='simulation_config[slaves][0][target_state]'] option[value='op'][selected]"
           )

    render_change(view, "change_simulation_config", %{
      "simulation_config" => %{
        "slaves" => %{
          "0" => %{
            "name" => "browser_outputs",
            "driver" => "EtherCAT.Driver.EL2809",
            "target_state" => "preop"
          }
        }
      }
    })

    rendered = render(view)
    assert rendered =~ "browser_outputs"

    assert has_element?(
             view,
             "input[name='simulation_config[slaves][0][name]'][value='browser_outputs']"
           )

    assert has_element?(
             view,
             "select[name='simulation_config[slaves][0][driver]'] option[value='EtherCAT.Driver.EL2809'][selected]"
           )

    assert has_element?(
             view,
             "select[name='simulation_config[slaves][0][target_state]'] option[value='preop'][selected]"
           )
  end

  test "simulator-backed ethercat sessions keep the master card first and bus watch second" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/ethercat")

    assert_eventually(fn ->
      rendered = render(view)
      {master_pos, _} = :binary.match(rendered, "data-test=\"hardware-section-master\"")
      {status_pos, _} = :binary.match(rendered, "data-test=\"hardware-section-bus-watch\"")

      assert rendered =~ "Master runtime is active"
      assert rendered =~ "Observed slaves on the current bus"
      assert has_element?(view, "[data-test='master-config-form']")
      refute has_element?(view, "[data-test='master-scan']")
      assert has_element?(view, "[data-test='stop-master']")
      assert master_pos < status_pos
      refute rendered =~ "Draft / Test"
      refute rendered =~ "Candidate vs Armed"
      refute rendered =~ "Capture / Baseline"
      refute rendered =~ "Provisioning"
      refute rendered =~ "Saved Snapshots"
      refute rendered =~ "Observed EtherCAT endpoints"
    end)
  end

  test "scan updates the master card from the current bus" do
    assert {:ok, _runtime} =
             HardwareGateway.start_simulation_config(
               HardwareGateway.default_ethercat_simulation_form()
             )

    {:ok, view, _html} = live(build_conn(), "/studio/ethercat")

    view
    |> element("[data-test='master-scan']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "master scan synced from live bus"
      assert rendered =~ "watched 3 slave(s)"

      assert has_element?(
               view,
               "input[name='simulation_config[slaves][0][name]'][value='coupler']"
             )

      assert has_element?(
               view,
               "input[name='simulation_config[slaves][1][name]'][value='inputs']"
             )

      assert has_element?(
               view,
               "input[name='simulation_config[slaves][2][name]'][value='outputs']"
             )

      assert has_element?(
               view,
               "select[name='simulation_config[slaves][0][driver]'] option[value='EtherCAT.Driver.EK1100'][selected]"
             )

      assert has_element?(
               view,
               "select[name='simulation_config[slaves][1][driver]'] option[value='EtherCAT.Driver.EL1809'][selected]"
             )

      assert has_element?(
               view,
               "select[name='simulation_config[slaves][2][driver]'] option[value='EtherCAT.Driver.EL2809'][selected]"
             )

      assert has_element?(
               view,
               "select[name='simulation_config[slaves][0][target_state]'] option[value='op'][selected]"
             )
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
      assert rendered =~ "operational"
      assert %Master.Status{lifecycle: :operational} = Master.status()
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
