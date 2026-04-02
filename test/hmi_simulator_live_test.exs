defmodule Ogol.HMI.SimulatorLiveTest do
  use Ogol.ConnCase, async: false

  alias EtherCAT.Backend
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias Ogol.Runtime.Hardware.Gateway, as: HardwareGateway
  alias Ogol.Studio.Examples
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

  test "renders the simulator page as a runtime view derived from the hardware config" do
    {:ok, view, html} = live(build_conn(), "/studio/simulator")

    assert html =~ "Simulator Studio"
    assert html =~ "Derived from current hardware config"
    assert has_element?(view, "[data-test='start-simulation']")
    assert has_element?(view, "[data-test='simulation-config-source']")
    assert html =~ "Edit Hardware Config"
    refute html =~ "simulator_cell do"
    refute has_element?(view, "[data-test='simulation-config-form']")
  end

  test "source preview comes from the current hardware config module" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    rendered = render(view)

    assert has_element?(view, "[data-test='simulation-config-source']")
    assert rendered =~ "defmodule Ogol.Generated.Hardware.Config.EtherCAT"
    assert rendered =~ "def definition"
    refute rendered =~ "def ensure_ready"
    refute rendered =~ "def stop"
    assert rendered =~ "Ogol.Hardware.Config.EtherCAT"
  end

  test "revision query does not replace the current workspace hardware config on simulator page" do
    assert {:ok, %Revisions.Revision{id: "r1"}} =
             Revisions.deploy_current(app_id: "ogol", topology_id: "packaging_line")

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

  test "starts an ethercat simulation from the current hardware config" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    view
    |> element("[data-test='start-simulation']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Current simulator state"
      assert has_element?(view, "[data-test='simulation-stop-current']")

      assert match?(
               %Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle],
               Master.status()
             )

      assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    end)
  end

  test "running simulation keeps the stop control on the derived runtime page" do
    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    view
    |> element("[data-test='start-simulation']")
    |> render_click()

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='simulation-stop-current']")
      refute has_element?(view, "[data-test='start-simulation']")
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

  test "starting simulation does not flatten a source-only watering hardware config" do
    assert {:ok, _example, _revision_file, _report} =
             Examples.load_into_workspace("watering_valves")

    {:ok, view, _html} = live(build_conn(), "/studio/simulator")

    view
    |> element("[data-test='start-simulation']")
    |> render_click()

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='simulation-stop-current']")
      assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    end)

    assert %Ogol.Hardware.Config.EtherCAT{} =
             config = Session.fetch_hardware_config_model("ethercat")

    outputs = Enum.find(config.slaves, &(&1.name == :outputs))

    assert outputs.driver == Ogol.Hardware.EtherCAT.Driver.EL2809
    assert outputs.aliases[:ch1] == :valve_1_open?

    assert {:ok, _result} = Ogol.Runtime.compile(:topology, "watering_system")

    assert {:ok, %{module: Ogol.Generated.Topologies.WateringSystem}} =
             Ogol.Runtime.deploy_topology("watering_system")
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
