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

  test "renders the simulator adapter library" do
    {:ok, view, html} = live(build_conn(), "/studio/simulator")

    assert html =~ "Simulator Studio"
    assert has_element?(view, "a[href='/studio/simulator/ethercat']")
    assert html =~ "EtherCAT"
  end

  test "renders the ethercat simulator page as a normal studio cell" do
    {:ok, view, html} = live(build_conn(), "/studio/simulator/ethercat")

    assert html =~ "Simulator Studio"
    assert html =~ "EtherCAT simulator runtime"
    assert has_element?(view, "[data-test='simulator-config-form']")
    assert has_element?(view, "button", "Start Simulation")
    assert has_element?(view, "button", "Reset From Hardware")
    assert html =~ "Connections"
    assert has_element?(view, "[data-test='simulator-view-config']")
    assert has_element?(view, "[data-test='simulator-view-source']")
  end

  test "source preview comes from the current simulator opts module" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator/ethercat")

    view
    |> element("[data-test='simulator-view-source']")
    |> render_click()

    assert_patch(view, "/studio/simulator/ethercat/source")

    rendered = render(view)

    assert has_element?(view, "[data-test='simulator-config-source']")
    assert rendered =~ "defmodule Ogol.Generated.Simulator.Config.EtherCAT"
    assert rendered =~ "def simulator_opts do"
    assert rendered =~ "EtherCAT.Simulator.Slave.from_driver"
    assert rendered =~ "backend: {:udp"
    assert rendered =~ "connections:"
    refute rendered =~ "__struct__:"
  end

  test "revision query is ignored and simulator page still reflects the current workspace" do
    assert {:ok, %Revisions.Revision{id: "r1"}} =
             Revisions.deploy_current(app_id: "ogol")

    {:ok, config} =
      HardwareGateway.default_ethercat_hardware_form()
      |> Map.put("transport", "raw")
      |> Map.put("primary_interface", "eth-test0")
      |> HardwareGateway.preview_ethercat_hardware_form()

    assert %Session.Workspace.SourceDraft{} = Session.put_hardware_config(config)

    {:ok, _view, html} = live(build_conn(), "/studio/simulator/ethercat?revision=r1")

    assert html =~ "raw eth-test0"

    assert Session.fetch_simulator_config_model("ethercat").backend ==
             {:raw, %{interface: "eth-test0"}}
  end

  test "shows running simulator state when the runtime is started externally" do
    EthercatHmiFixture.boot_simulator_only!()

    {:ok, view, _html} = live(build_conn(), "/studio/simulator/ethercat")

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Simulator running"
      assert rendered =~ "udp port"
      assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    end)
  end

  test "starts an ethercat simulation from the current hardware config" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator/ethercat")

    view
    |> element("[data-test='start-simulation']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation started"
      assert rendered =~ "Simulator running"
      assert has_element?(view, "[data-test='simulation-stop-current']")
      assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    end)
  end

  test "stopping simulation from the simulator page stops the simulator runtime" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator/ethercat")

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
      assert rendered =~ "simulation stopped"
      assert has_element?(view, "[data-test='start-simulation']")
      refute has_element?(view, "[data-test='simulation-stop-current']")
    end)
  end

  test "cell route renders only the simulator body projection" do
    {:ok, _view, html} = live(build_conn(), "/studio/cells/simulator/ethercat/source")

    assert html =~ "defmodule Ogol.Generated.Simulator.Config.EtherCAT"
    assert html =~ "def simulator_opts do"
    refute html =~ "Simulator Studio"
    refute html =~ "Start Simulation"
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
