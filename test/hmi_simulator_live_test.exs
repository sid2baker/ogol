defmodule Ogol.HMI.SimulatorLiveTest do
  use Ogol.ConnCase, async: false

  alias EtherCAT.Backend
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias Ogol.HMI.HardwareGateway
  alias Ogol.Studio.RevisionStore
  alias Ogol.Studio.WorkspaceStore
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
    assert rendered =~ "defmodule Ogol.Generated.HardwareConfig"
    assert rendered =~ "def config"
    assert rendered =~ "def ethercat_config"
    assert rendered =~ "Ogol.HardwareConfig"
  end

  test "revision mode shows that simulator config comes from the selected revision" do
    assert {:ok, %RevisionStore.Revision{id: "r1"}} =
             RevisionStore.deploy_current(app_id: "ogol_bundle")

    {:ok, config} =
      HardwareGateway.default_ethercat_simulation_form()
      |> Map.put("label", "Current Target Ring")
      |> HardwareGateway.preview_ethercat_simulation_config()

    assert %WorkspaceStore.HardwareConfigDraft{} = WorkspaceStore.put_hardware_config(config)

    {:ok, _view, html} = live(build_conn(), "/studio/simulator?revision=r1")

    assert html =~ "Simulator config comes from the selected revision"
    refute html =~ "Current Target Ring"
    assert html =~ "EtherCAT Demo Ring"
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
