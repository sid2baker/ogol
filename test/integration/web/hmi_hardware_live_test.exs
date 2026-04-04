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
    assert has_element?(view, "[data-test='ethercat-driver-library']")
    assert has_element?(view, "[data-test='hardware-driver-form']")
  end

  test "switches between config and source while keeping the driver cell on the ethercat page" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    view
    |> element("[data-test='hardware-view-source']")
    |> render_click()

    assert_patch(view, "/studio/hardware/ethercat/source")

    rendered = render(view)
    assert has_element?(view, "[data-test='hardware-config-source']")
    assert has_element?(view, "[data-test='ethercat-driver-library']")
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

  test "driver editor shows canonical ethercat signal names" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    rendered = render(view)
    assert rendered =~ "/studio/hardware/ethercat/drivers/coupler"
    assert rendered =~ "/studio/hardware/ethercat/drivers/inputs"
    assert rendered =~ "/studio/hardware/ethercat/drivers/outputs"
    assert rendered =~ "Canonical Signals"
    assert rendered =~ "ch1"
    assert rendered =~ "ch2"
    refute rendered =~ "aliases_text"
  end

  test "driver cell lives under the ethercat folder and focuses one slave driver" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    view
    |> element("[data-test='hardware-driver-cell-link-2']")
    |> render_click()

    assert_patch(view, "/studio/hardware/ethercat/drivers/outputs")

    rendered = render(view)
    assert rendered =~ "EtherCAT Driver"
    assert rendered =~ "Outputs"
    assert rendered =~ "Back To Drivers"
    refute rendered =~ "Open Driver Cell"
  end

  test "legacy driver overview path redirects back to the ethercat page" do
    assert {:error, {:live_redirect, %{to: "/studio/hardware/ethercat", flash: %{}}}} =
             live(build_conn(), "/studio/hardware/ethercat/drivers")
  end

  test "driver cell body route renders the focused driver body only" do
    {:ok, _view, html} = live(build_conn(), "/studio/cells/hardware/ethercat/drivers/outputs")

    assert html =~ "EtherCAT Driver"
    assert html =~ "Outputs"
    refute html =~ "Hardware Studio"
    refute html =~ "Compile"
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
