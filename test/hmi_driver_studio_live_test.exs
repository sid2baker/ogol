defmodule Ogol.HMI.DriverStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore
  alias Ogol.Studio.Modules
  alias Ogol.Studio.RevisionStore

  test "renders the driver studio workspace" do
    {:ok, view, html} = live(build_conn(), "/studio/drivers")

    assert html =~ "Drivers"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "packaging_outputs"
    assert has_element?(view, "button", "Build")
    refute has_element?(view, "button[disabled]", "Build")
    refute has_element?(view, "button", "Apply")
  end

  test "new driver opens as a new draft from the library action" do
    {:ok, view, _html} = live(build_conn(), "/studio/drivers")

    render_click(view, "new_driver", %{})
    path = "/studio/drivers/driver_1"
    assert_patch(view, path)

    {:ok, _view, html} = live(build_conn(), path)
    assert html =~ "Driver 1"
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

    render_click(view, "request_transition", %{"transition" => "build"})
    assert has_element?(view, "button[disabled]", "Build")
    assert has_element?(view, "button", "Apply")

    render_click(view, "request_transition", %{"transition" => "apply"})
    refute has_element?(view, "button", "Apply")
    assert has_element?(view, "button[disabled]", "Build")

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

    render_click(view, "select_view", %{"view" => "source"})

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

  test "revision query shows a saved driver revision without mutating the working draft" do
    revision_model =
      DriverDefinition.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Revision")

    DriverDraftStore.save_source(
      "packaging_outputs",
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(revision_model.module_name),
        revision_model
      ),
      revision_model,
      :synced,
      []
    )

    assert {:ok, %RevisionStore.Revision{id: "r1"}} =
             RevisionStore.deploy_current(app_id: "ogol_bundle")

    draft_model =
      DriverDefinition.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Draft")

    DriverDraftStore.save_source(
      "packaging_outputs",
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(draft_model.module_name),
        draft_model
      ),
      draft_model,
      :synced,
      []
    )

    {:ok, _view, html} = live(build_conn(), "/studio/drivers/packaging_outputs?revision=r1")
    assert html =~ "Packaging Outputs Revision"
    assert DriverDraftStore.fetch("packaging_outputs").model.label == "Packaging Outputs Draft"

    {:ok, _view, html} = live(build_conn(), "/studio/drivers/packaging_outputs?revision=")
    assert html =~ "Packaging Outputs Draft"
    assert DriverDraftStore.fetch("packaging_outputs").model.label == "Packaging Outputs Draft"
  end

  test "revision browsing is url-scoped and does not leak into draft sessions" do
    revision_model =
      DriverDefinition.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Revision")

    DriverDraftStore.save_source(
      "packaging_outputs",
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(revision_model.module_name),
        revision_model
      ),
      revision_model,
      :synced,
      []
    )

    assert {:ok, %RevisionStore.Revision{id: "r1"}} =
             RevisionStore.deploy_current(app_id: "ogol_bundle")

    draft_model =
      DriverDefinition.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Draft")

    DriverDraftStore.save_source(
      "packaging_outputs",
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(draft_model.module_name),
        draft_model
      ),
      draft_model,
      :synced,
      []
    )

    {:ok, _revision_view, revision_html} =
      live(build_conn(), "/studio/drivers/packaging_outputs?revision=r1")

    assert revision_html =~ "Packaging Outputs Revision"

    {:ok, _draft_view, draft_html} = live(build_conn(), "/studio/drivers/packaging_outputs")

    assert draft_html =~ "Packaging Outputs Draft"
  end
end
