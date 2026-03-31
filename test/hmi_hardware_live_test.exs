defmodule Ogol.HMI.EthercatLiveTest do
  use Ogol.ConnCase, async: false

  alias EtherCAT.Master
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

  test "renders the hardware page around one hardware config plus derived runtime panels" do
    {:ok, view, html} = live(build_conn(), "/studio/hardware")

    assert html =~ "Hardware Studio"
    assert has_element?(view, "[data-test='hardware-config-studio']")
    assert has_element?(view, "[data-test='hardware-config-form']")
    assert has_element?(view, "[data-test='hardware-section-simulator']")
    assert has_element?(view, "[data-test='hardware-section-master']")
    assert has_element?(view, "[data-test='start-simulation']")
    assert has_element?(view, "[data-test='master-scan']")
    refute html =~ "master_cell do"
    refute html =~ "simulator_cell do"
  end

  test "hardware config can toggle between visual and source views" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    refute has_element?(view, "[data-test='hardware-config-source']")
    assert has_element?(view, "[data-test='hardware-config-form']")

    view
    |> element("[data-test='hardware-config-view-source']")
    |> render_click()

    rendered = render(view)

    assert has_element?(view, "[data-test='hardware-config-source']")
    assert rendered =~ "defmodule Ogol.Generated.HardwareConfig"
    assert rendered =~ "def config"
    assert rendered =~ "def ethercat_config"
    assert rendered =~ "Ogol.HardwareConfig"
  end

  test "revision mode shows that ethercat config comes from the selected revision" do
    assert {:ok, %RevisionStore.Revision{id: "r1"}} =
             RevisionStore.deploy_current(app_id: "ogol_bundle")

    {:ok, config} =
      HardwareGateway.default_ethercat_simulation_form()
      |> put_in(["slaves", Access.at(0), "name"], "current_target_coupler")
      |> HardwareGateway.preview_ethercat_simulation_config()

    assert %WorkspaceStore.HardwareConfigDraft{} = WorkspaceStore.put_hardware_config(config)

    {:ok, view, html} = live(build_conn(), "/studio/hardware?revision=r1")

    assert html =~ "EtherCAT config comes from the selected revision"

    refute has_element?(
             view,
             "input[name='simulation_config[slaves][0][name]'][value='current_target_coupler']"
           )

    assert has_element?(
             view,
             "input[name='simulation_config[slaves][0][name]'][value='coupler']"
           )
  end

  test "running master shows the runtime panel without a separate cell mode" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Master runtime is active"
      assert has_element?(view, "[data-test='master-runtime-view']")
      refute has_element?(view, "[data-test='master-view-runtime']")
    end)
  end

  test "hardware config form lets you edit watched slaves directly" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    assert has_element?(view, "[data-test='hardware-config-watched-slaves']")
    assert has_element?(view, "[data-test='hardware-config-slave-row-0']")

    render_change(view, "change_simulation_config", %{
      "simulation_config" => %{
        "slaves" => %{
          "0" => %{
            "name" => "browser_outputs",
            "driver" => "Ogol.Hardware.EtherCAT.Driver.EL2809",
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
             "select[name='simulation_config[slaves][0][driver]'] option[value='Ogol.Hardware.EtherCAT.Driver.EL2809'][selected]"
           )

    assert has_element?(
             view,
             "select[name='simulation_config[slaves][0][target_state]'] option[value='preop'][selected]"
           )
  end

  test "hardware config source reflects transport changes" do
    Application.put_env(:ogol, :ethercat_available_interfaces, ["eth-test0", "eth-test1"])

    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    render_change(view, "change_simulation_config", %{
      "simulation_config" => %{
        "transport" => "raw",
        "primary_interface" => "eth-test0"
      }
    })

    view
    |> element("[data-test='hardware-config-view-source']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "mode: :raw"
    assert rendered =~ "eth-test0"

    view
    |> element("[data-test='hardware-config-view-visual']")
    |> render_click()

    render_change(view, "change_simulation_config", %{
      "simulation_config" => %{
        "transport" => "redundant",
        "primary_interface" => "eth-test0",
        "secondary_interface" => "eth-test1"
      }
    })

    assert has_element?(view, "select[name='simulation_config[primary_interface]']")
    assert has_element?(view, "select[name='simulation_config[secondary_interface]']")
  end

  test "scan updates the shared hardware config from the current bus" do
    assert {:ok, _runtime} =
             HardwareGateway.start_simulation_config(
               HardwareGateway.default_ethercat_simulation_form()
             )

    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    view
    |> element("[data-test='master-scan']")
    |> render_click()

    assert_eventually(fn ->
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
    end)
  end

  test "the hardware page can stop and restart the master against the running simulator" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

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

  defp restore_available_interfaces(nil) do
    Application.delete_env(:ogol, :ethercat_available_interfaces)
  end

  defp restore_available_interfaces(interfaces) do
    Application.put_env(:ogol, :ethercat_available_interfaces, interfaces)
  end
end
