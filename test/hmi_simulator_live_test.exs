defmodule Ogol.HMI.SimulatorLiveTest do
  use Ogol.ConnCase, async: false

  alias EtherCAT.Backend
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias Ogol.Runtime.Hardware.Gateway, as: HardwareGateway
  alias Ogol.Session.Revisions
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  setup do
    previous_interfaces = Application.get_env(:ogol, :ethercat_available_interfaces)
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      restore_available_interfaces(previous_interfaces)
      EthercatHmiFixture.stop_all!()
    end)

    :ok
  end

  test "renders the simulator page as a managed projection derived from the hardware config" do
    {:ok, view, html} = live(build_conn(), "/studio/simulator")

    assert html =~ "Simulator Studio"
    assert html =~ "Derived from current EtherCAT config"
    assert has_element?(view, "[data-test='simulator-runtime-status']")
    assert has_element?(view, "[data-test='simulation-config-source']")
    assert html =~ "Open Hardware Config"
    assert has_element?(view, "[data-test='start-simulation']")
    refute has_element?(view, "[data-test='simulation-stop-current']")
  end

  test "source preview comes from the current hardware config module and uses struct syntax" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    rendered = render(view)

    assert has_element?(view, "[data-test='simulation-config-source']")
    assert rendered =~ "defmodule Ogol.Generated.Hardware.Config.EtherCAT"
    assert rendered =~ "%Ogol.Hardware.Config.EtherCAT.Domain{"
    assert rendered =~ "%EtherCAT.Slave.Config{"
    refute rendered =~ "__struct__:"
  end

  test "revision query is ignored and simulator page still reflects the current workspace" do
    assert {:ok, %Revisions.Revision{id: "r1"}} =
             Revisions.deploy_current(app_id: "ogol")

    {:ok, config} =
      HardwareGateway.default_ethercat_simulation_form()
      |> Map.put("label", "Current Target Ring")
      |> HardwareGateway.preview_ethercat_simulation_config()

    assert %Session.Workspace.SourceDraft{} = Session.put_hardware_config(config)

    {:ok, _view, html} = live(build_conn(), "/studio/simulator?revision=r1")

    assert html =~ "Current Target Ring"
    refute html =~ "EtherCAT Demo Ring"
    assert Session.fetch_hardware_config_model("ethercat").label == "Current Target Ring"
  end

  test "shows running simulator state when the runtime is started externally" do
    EthercatHmiFixture.boot_simulator_only!()

    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Simulator running"
      assert rendered =~ "udp port"
      assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    end)
  end

  test "starts an ethercat simulation from the current hardware config" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    view
    |> element("[data-test='start-simulation']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation started from ethercat_demo"
      assert rendered =~ "Simulator running"
      assert has_element?(view, "[data-test='simulation-stop-current']")
      assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    end)
  end

  test "stopping simulation from the simulator page stops the simulator runtime" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    view
    |> element("[data-test='start-simulation']")
    |> render_click()

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='simulation-stop-current']")
    end)

    view
    |> element("[data-test='simulation-stop-current']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation stopped for ethercat_demo"
      assert has_element?(view, "[data-test='start-simulation']")
      refute has_element?(view, "[data-test='simulation-stop-current']")
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

  defp restore_available_interfaces(nil) do
    Application.delete_env(:ogol, :ethercat_available_interfaces)
  end

  defp restore_available_interfaces(interfaces) do
    Application.put_env(:ogol, :ethercat_available_interfaces, interfaces)
  end
end
