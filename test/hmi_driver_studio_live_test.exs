defmodule Ogol.HMI.DriverStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Modules

  test "renders the driver studio workspace" do
    {:ok, _view, html} = live(build_conn(), "/studio/drivers")

    assert html =~ "Generated Module Artifact"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "Save Draft"
    assert html =~ "Build"
    assert html =~ "Apply"
    assert html =~ "packaging_outputs"
    assert html =~ "Apply Status"
  end

  test "visual edits update source and can be built and applied" do
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
    assert render(view) =~ "Visuals synced"

    render_click(view, "build_driver")
    assert render(view) =~ "Build complete"

    render_click(view, "apply_driver")
    assert render(view) =~ "Applied"
    assert render(view) =~ "applied"

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

    assert html =~ "Visuals unavailable"
    assert html =~ "Visual editor unavailable"
    assert html =~ "Current source can no longer be represented"
  end
end
