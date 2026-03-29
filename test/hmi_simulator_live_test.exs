defmodule Ogol.HMI.SimulatorLiveTest do
  use Ogol.ConnCase, async: false

  alias EtherCAT.Backend
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias Ogol.HMI.HardwareSnapshot
  alias Ogol.HMI.SnapshotStore
  alias Ogol.TestSupport.EthercatHmiFixture

  setup do
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      EthercatHmiFixture.stop_all!()
    end)

    :ok
  end

  test "renders the simulator page without an active backend" do
    {:ok, _view, html} = live(build_conn(), "/studio/simulator")

    assert html =~ "Simulator Studio"
    assert html =~ "Start simulation"
    assert html =~ "Draft ring"
    refute html =~ "Current simulator state"
    refute html =~ "Master cell"
    refute html =~ "EtherCAT Studio"
  end

  test "simulation editor exposes only quick ring-shape fields" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    assert has_element?(view, "select[name='simulation_config[slaves][0][driver]']")
    refute has_element?(view, "input[name='simulation_config[bind_ip]']")
    refute has_element?(view, "input[name='simulation_config[simulator_ip]']")
    refute has_element?(view, "input[name='simulation_config[scan_stable_ms]']")
    refute has_element?(view, "input[name='simulation_config[frame_timeout_ms]']")
    refute has_element?(view, "select[name='simulation_config[slaves][0][target_state]']")
    refute has_element?(view, "select[name='simulation_config[slaves][0][process_data_domain]']")
    refute has_element?(view, "input[name='simulation_config[slaves][0][health_poll_ms]']")
  end

  test "simulation driver selects keep their chosen values across re-render" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    rendered =
      view
      |> form("[data-test='simulation-config-form']", %{
        "simulation_config" => %{
          "id" => "ethercat_demo",
          "label" => "EtherCAT Demo Ring",
          "slaves" => %{
            "0" => %{"name" => "coupler", "driver" => "EtherCAT.Driver.EK1100"},
            "1" => %{"name" => "inputs", "driver" => "EtherCAT.Driver.EL1809"},
            "2" => %{"name" => "outputs", "driver" => "EtherCAT.Driver.EL2809"}
          }
        }
      })
      |> render_change()

    assert Regex.match?(
             ~r/<option[^>]*(value="EtherCAT.Driver.EK1100"[^>]*selected|selected[^>]*value="EtherCAT.Driver.EK1100")/,
             rendered
           )

    assert Regex.match?(
             ~r/<option[^>]*(value="EtherCAT.Driver.EL2809"[^>]*selected|selected[^>]*value="EtherCAT.Driver.EL2809")/,
             rendered
           )
  end

  test "simulator cell can toggle between visual and source views" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    refute has_element?(view, "[data-test='simulation-cell-source']")

    view
    |> element("[data-test='simulator-mode-source']")
    |> render_click()

    assert has_element?(view, "[data-test='simulation-cell-source']")
    assert render(view) =~ "simulator_cell do"
  end

  test "stale hardware snapshots do not block simulator authoring" do
    :ok =
      SnapshotStore.put_hardware(%HardwareSnapshot{
        bus: :ethercat,
        endpoint_id: :coupler,
        connected?: true,
        last_feedback_at: System.system_time(:millisecond) - 10_000
      })

    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    assert has_element?(view, "[data-test='simulation-config-form']")

    view
    |> element("[data-test='add-simulation-slave']")
    |> render_click()

    assert render(view) =~ "Slave 4"
  end

  test "starts an ethercat simulation from the simulator draft" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    view
    |> form("[data-test='simulation-config-form']", %{
      "simulation_config" => %{
        "id" => "packaging_line",
        "label" => "Packaging Line",
        "slaves" => %{
          "0" => %{"name" => "coupler", "driver" => "EtherCAT.Driver.EK1100"},
          "1" => %{"name" => "inputs", "driver" => "EtherCAT.Driver.EL1809"},
          "2" => %{"name" => "outputs", "driver" => "EtherCAT.Driver.EL2809"}
        }
      }
    })
    |> render_change()

    view
    |> element("[data-test='start-simulation']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Current simulator state"
      assert rendered =~ "The simulator is already running."
      assert has_element?(view, "[data-test='simulation-stop-current']")

      assert match?(
               %Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle],
               Master.status()
             )

      assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    end)
  end

  test "running simulation switches to the current-state stop control" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    view
    |> form("[data-test='simulation-config-form']", %{
      "simulation_config" => %{
        "id" => "running_card",
        "label" => "Running Card",
        "slaves" => %{
          "0" => %{"name" => "coupler", "driver" => "EtherCAT.Driver.EK1100"},
          "1" => %{"name" => "inputs", "driver" => "EtherCAT.Driver.EL1809"},
          "2" => %{"name" => "outputs", "driver" => "EtherCAT.Driver.EL2809"}
        }
      }
    })
    |> render_change()

    view
    |> element("[data-test='start-simulation']")
    |> render_click()

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='simulation-stop-current']")
      refute has_element?(view, "[data-test='start-simulation']")

      assert match?(
               %Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle],
               Master.status()
             )

      assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    end)

    view
    |> element("[data-test='simulation-stop-current']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Start simulation"
      assert has_element?(view, "[data-test='start-simulation']")
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
