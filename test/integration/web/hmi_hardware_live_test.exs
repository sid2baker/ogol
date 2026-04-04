defmodule Ogol.HMI.HardwareLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Runtime
  alias Ogol.Session

  test "renders the hardware adapter library" do
    {:ok, view, html} = live(build_conn(), "/studio/hardware")

    assert html =~ "Hardware Studio"
    assert has_element?(view, "a[href='/studio/hardware/ethercat']")
    assert html =~ "EtherCAT"
  end

  test "renders the ethercat config page as a normal studio cell" do
    {:ok, view, html} = live(build_conn(), "/studio/hardware/ethercat")

    assert html =~ "Hardware Studio"
    assert html =~ "Author the canonical EtherCAT hardware"
    assert has_element?(view, "[data-test='hardware-config-form']")
    assert has_element?(view, "button", "Compile")
    assert has_element?(view, "[data-test='hardware-view-config']")
    assert has_element?(view, "[data-test='hardware-view-source']")
    assert has_element?(view, "[data-test='ethercat-driver-library-link']")
    refute has_element?(view, "[data-test='ethercat-driver-library']")
  end

  test "switches between config and source on the hardware page only" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    view
    |> element("[data-test='hardware-view-source']")
    |> render_click()

    assert_patch(view, "/studio/hardware/ethercat/source")

    rendered = render(view)
    assert has_element?(view, "[data-test='hardware-config-source']")
    assert has_element?(view, "[data-test='ethercat-driver-library-link']")
    refute has_element?(view, "[data-test='ethercat-driver-library']")
    assert rendered =~ "defmodule Ogol.Generated.Hardware.EtherCAT"
    assert rendered =~ "use Ogol.Hardware"
    assert rendered =~ "def dispatch_command"
    assert rendered =~ "def write_output"
    assert rendered =~ "%Ogol.Hardware.EtherCAT.Domain{"
    assert rendered =~ "%EtherCAT.Slave.Config{"
    refute rendered =~ "__struct__:"
    refute rendered =~ "def ensure_ready"
    refute rendered =~ "def stop do"
  end

  test "visual edits persist the canonical ethercat hardware draft" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    render_change(view, "change_visual", %{
      "hardware" => %{
        "id" => "packaging_ring",
        "label" => "Packaging Ring",
        "transport" => "raw",
        "primary_interface" => "eth-test0"
      }
    })

    assert hardware_draft = Session.fetch_hardware("ethercat")
    assert hardware_draft.source =~ "defmodule Ogol.Generated.Hardware.EtherCAT"
    assert hardware_draft.source =~ "use Ogol.Hardware"
    assert hardware_draft.source =~ ~s(id: "packaging_ring")
    assert hardware_draft.source =~ "mode: :raw"
    assert hardware_draft.source =~ ~s(primary_interface: "eth-test0")
  end

  test "raw transport only shows interface fields and never authors simulator ip" do
    {:ok, view, html} = live(build_conn(), "/studio/hardware/ethercat")

    assert html =~ "hardware[bind_ip]"
    refute html =~ "hardware[simulator_ip]"
    refute html =~ "ethercat-interfaces"

    render_change(view, "change_visual", %{
      "hardware" => %{
        "transport" => "raw"
      }
    })

    rendered = render(view)
    refute rendered =~ "hardware[bind_ip]"
    refute rendered =~ "hardware[simulator_ip]"
    assert rendered =~ "hardware[primary_interface]"
    refute rendered =~ "hardware[secondary_interface]"
  end

  test "hardware page links to the ethercat driver library page" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    assert has_element?(view, "a[href='/studio/hardware/ethercat/drivers']", "Open Drivers")
  end

  test "driver library page lists real ethercat drivers" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat/drivers")

    rendered = render(view)
    assert rendered =~ "/studio/hardware/ethercat/drivers/ek1100"
    assert rendered =~ "/studio/hardware/ethercat/drivers/el1809"
    assert rendered =~ "/studio/hardware/ethercat/drivers/el2809"
    assert rendered =~ "EK1100"
    assert rendered =~ "EL1809"
    assert rendered =~ "EL2809"
    refute rendered =~ "exposes ch1"
  end

  test "driver cell lives under the ethercat folder and focuses one real driver" do
    {:ok, view, rendered} = live(build_conn(), "/studio/hardware/ethercat/drivers/el2809")

    assert rendered =~ "EtherCAT Driver"
    assert rendered =~ "EL2809"
    assert rendered =~ "Back To Drivers"
    assert has_element?(view, "[data-test='ethercat-driver-config']")
    assert has_element?(view, "[data-test='driver-view-config']")
    assert has_element?(view, "[data-test='driver-view-source']")
    assert rendered =~ "Canonical Signals"
    assert rendered =~ "ch1"
  end

  test "driver studio cell switches between config and source views" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat/drivers/el2809")

    assert has_element?(view, "[data-test='driver-view-config']")
    assert has_element?(view, "[data-test='driver-view-source']")

    view
    |> element("[data-test='driver-view-source']")
    |> render_click()

    assert_patch(view, "/studio/hardware/ethercat/drivers/el2809/source")

    rendered = render(view)
    assert has_element?(view, "[data-test='hardware-driver-source']")
    assert rendered =~ "defmodule Ogol.Hardware.EtherCAT.Driver.EL2809"
    assert rendered =~ "def command("
  end

  test "driver cell recompiles the selected real driver" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat/drivers/el2809")

    assert has_element?(view, "button", "Recompile")
    refute has_element?(view, "button", "Compile")

    render_click(view, "request_transition", %{"transition" => "recompile"})

    assert has_element?(view, "button", "Recompile")
    refute render(view) =~ "Compile failed"
  end

  test "driver page keeps the recompile state across refresh" do
    {:ok, _view, html} = live(build_conn(), "/studio/hardware/ethercat/drivers/el2809")

    assert html =~ "Recompile"
    refute html =~ ">Compile<"
  end

  test "driver cell body route renders the focused driver body only" do
    {:ok, _view, html} = live(build_conn(), "/studio/cells/hardware/ethercat/drivers/el2809")

    assert html =~ "Driver Module"
    assert html =~ "EL2809"
    refute html =~ "Hardware Studio"
    refute html =~ "Compile"
    refute html =~ "Back To Drivers"
    refute html =~ "Defined workspace drivers"
  end

  test "driver cell source route renders the focused driver source only" do
    {:ok, _view, html} =
      live(build_conn(), "/studio/cells/hardware/ethercat/drivers/el2809/source")

    assert html =~ "defmodule Ogol.Hardware.EtherCAT.Driver.EL2809"
    assert html =~ "def command("
    refute html =~ "Hardware Studio"
    refute html =~ "Compile"
    refute html =~ "Back To Drivers"
    refute html =~ "Defined workspace drivers"
  end

  test "compile action builds the canonical ethercat hardware artifact" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    render_click(view, "request_transition", %{"transition" => "compile"})

    assert {:ok, module} = Runtime.current(:hardware, "ethercat")
    assert %Ogol.Hardware.EtherCAT{} = module.hardware()
  end

  test "cell route renders only the body projection" do
    {:ok, _view, html} = live(build_conn(), "/studio/cells/hardware/ethercat/source")

    assert html =~ "defmodule Ogol.Generated.Hardware.EtherCAT"
    refute html =~ "Hardware Studio"
    refute html =~ "Compile"
  end
end
