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
    assert html =~ "Author the canonical EtherCAT hardware config"
    assert has_element?(view, "[data-test='hardware-config-form']")
    assert has_element?(view, "button", "Compile")
    assert has_element?(view, "[data-test='hardware-view-config']")
    assert has_element?(view, "[data-test='hardware-view-drivers']")
    assert has_element?(view, "[data-test='hardware-view-source']")
  end

  test "switches between config, drivers, and source views" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    view
    |> element("[data-test='hardware-view-drivers']")
    |> render_click()

    assert_patch(view, "/studio/hardware/ethercat/drivers")
    assert has_element?(view, "[data-test='hardware-driver-form']")

    view
    |> element("[data-test='hardware-view-source']")
    |> render_click()

    assert_patch(view, "/studio/hardware/ethercat/source")

    rendered = render(view)
    assert has_element?(view, "[data-test='hardware-config-source']")
    assert rendered =~ "defmodule Ogol.Generated.Hardware.Config.EtherCAT"
    refute rendered =~ "def ensure_ready"
    refute rendered =~ "def stop"
  end

  test "visual edits persist the canonical ethercat hardware draft" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    render_change(view, "change_visual", %{
      "hardware_config" => %{
        "id" => "packaging_ring",
        "label" => "Packaging Ring",
        "transport" => "raw",
        "primary_interface" => "eth-test0"
      }
    })

    assert hardware_draft = Session.fetch_hardware_config("ethercat")
    assert hardware_draft.source =~ "defmodule Ogol.Generated.Hardware.Config.EtherCAT"
    assert hardware_draft.source =~ ~s(id: "packaging_ring")
    assert hardware_draft.source =~ "mode: :raw"
    assert hardware_draft.source =~ ~s(primary_interface: "eth-test0")
  end

  test "driver alias edits persist inside the ethercat hardware config" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat/drivers")

    view
    |> element("[data-test='hardware-driver-2'] form")
    |> render_change(%{
      "hardware_config" => %{
        "slaves" => %{
          "2" => %{
            "aliases_text" => "ch1: valve_1_open?\nch2: valve_2_open?"
          }
        }
      }
    })

    assert hardware_draft = Session.fetch_hardware_config("ethercat")
    assert hardware_draft.source =~ "ch1: :valve_1_open?"
    assert hardware_draft.source =~ "ch2: :valve_2_open?"
  end

  test "compile action builds the canonical ethercat hardware artifact" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware/ethercat")

    render_click(view, "request_transition", %{"transition" => "compile"})

    assert {:ok, module} = Runtime.current(:hardware_config, "ethercat")
    assert %Ogol.Hardware.Config.EtherCAT{} = module.definition()
  end

  test "cell route renders only the body projection" do
    {:ok, _view, html} = live(build_conn(), "/studio/cells/hardware/ethercat/source")

    assert html =~ "defmodule Ogol.Generated.Hardware.Config.EtherCAT"
    refute html =~ "Hardware Studio"
    refute html =~ "Compile"
  end
end
