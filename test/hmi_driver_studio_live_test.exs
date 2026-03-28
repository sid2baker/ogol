defmodule Ogol.HMI.DriverStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Modules

  test "renders the driver studio workspace" do
    {:ok, view, html} = live(build_conn(), "/studio/drivers")

    assert html =~ "Studio Cell"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "packaging_outputs"
    assert has_element?(view, "button", "Build")
    refute has_element?(view, "button", "Apply")
  end

  test "visual edits autosave, build, and then enable apply" do
    {:ok, view, _html} = live(build_conn(), "/studio/drivers")

    render_change(view, "change_visual", %{
      "driver" => %{
        "id" => "packaging_outputs",
        "module_name" => "Ogol.Generated.Drivers.PackagingOutputs",
        "label" => "Packaging Outputs Runtime",
        "device_kind" => "digital_output",
        "vendor_id" => "2",
        "product_code" => "184103122",
        "revision" => "any",
        "channel_count" => "2",
        "channels" => %{
          "0" => %{"name" => "outfeed_ready", "invert?" => "false", "default" => "true"},
          "1" => %{"name" => "pusher_extend", "invert?" => "true", "default" => "false"}
        }
      }
    })

    assert render(view) =~ "Packaging Outputs Runtime"
    refute render(view) =~ "Visuals synced"

    {:ok, _reloaded, reloaded_html} = live(build_conn(), "/studio/drivers")
    assert reloaded_html =~ "Packaging Outputs Runtime"
    assert reloaded_html =~ "Build"
    refute reloaded_html =~ ">Apply<"

    render_click(view, "build_driver")
    assert has_element?(view, "button", "Apply")
    refute has_element?(view, "button", "Build")

    render_click(view, "apply_driver")
    assert render(view) =~ "Current source is applied"
    refute has_element?(view, "button", "Apply")

    assert {:ok, module} = Modules.current("packaging_outputs")
    assert inspect(module) =~ "PackagingOutputs"
  end

  test "unsupported source disables the visual editor honestly" do
    {:ok, view, _html} = live(build_conn(), "/studio/drivers")

    render_change(view, "change_source", %{
      "draft" => %{
        "source" => """
        defmodule FreehandDriver do
          def hello, do: :world
        end
        """
      }
    })

    html = render(view)

    assert html =~ "Visual editor unavailable"
    assert html =~ "Current source can no longer be represented"
  end

  test "invalid generated source stays in source mode and shows a warning" do
    {:ok, view, _html} = live(build_conn(), "/studio/drivers")

    render_click(view, "set_editor_mode", %{"mode" => "source"})

    render_change(view, "change_source", %{
      "draft" => %{
        "source" => """
        defmodule Ogol.Generated.Drivers.PackagingOutputs do
          @moduledoc "Generated EtherCAT driver for Packaging Outputs."
          @behaviour EtherCAT.Driver

          @ogol_driver_definition %{
            id: "packaging_outputs",
            label: "Packaging Outputs",
            revision: :any,
            channels: [
              %{default: false, name: :ch1, invert?: false},
              %{default: false, name: %{bad: :type}, invert?: false}
            ],
            device_kind: :digital_output,
            vendor_id: 2,
            product_code: 184102994
          }

          def definition, do: @ogol_driver_definition

          def identity, do: Ogol.Studio.DriverRuntime.identity(@ogol_driver_definition)
          def signal_model(config, sii_pdo_configs),
            do: Ogol.Studio.DriverRuntime.signal_model(@ogol_driver_definition, config, sii_pdo_configs)
          def encode_signal(signal, config, value),
            do: Ogol.Studio.DriverRuntime.encode_signal(@ogol_driver_definition, signal, config, value)
          def decode_signal(signal, config, raw),
            do: Ogol.Studio.DriverRuntime.decode_signal(@ogol_driver_definition, signal, config, raw)
          def init(config), do: Ogol.Studio.DriverRuntime.init(@ogol_driver_definition, config)
          def project_state(decoded_inputs, prev_state, driver_state, config),
            do: Ogol.Studio.DriverRuntime.project_state(@ogol_driver_definition, decoded_inputs, prev_state, driver_state, config)
          def command(command, projected_state, driver_state, config),
            do: Ogol.Studio.DriverRuntime.command(@ogol_driver_definition, command, projected_state, driver_state, config)
          def describe(config), do: Ogol.Studio.DriverRuntime.describe(@ogol_driver_definition, config)
        end
        """
      }
    })

    html = render(view)

    assert html =~ "Visual editor unavailable"
    assert html =~ "Current source can no longer be represented"
    assert html =~ "%{bad: :type}"
    assert has_element?(view, "button", "Source")
  end
end
