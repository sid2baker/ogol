defmodule Ogol.Studio.BundleTest do
  use ExUnit.Case, async: false

  alias Ogol.Studio.Bundle
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore

  setup do
    :ok = DriverDraftStore.reset()
    :ok
  end

  test "exports current driver drafts into a single bundle file" do
    {:ok, source} =
      Bundle.export_current(
        app_id: "packaging_line",
        title: "Packaging Line",
        versioning: %{
          bundle_revision: "r42",
          release: %{version: "1.3.0", classification: :minor, based_on: "1.2.4"}
        },
        workspace: %{open_artifact: {:driver, "packaging_outputs"}, editor_mode: :visual}
      )

    assert source =~ "defmodule Ogol.Bundle.PackagingLine do"
    assert source =~ "kind: :studio_bundle"
    assert source =~ "bundle_revision: \"r42\""
    assert source =~ "version: \"1.3.0\""
    assert source =~ "defmodule Ogol.Generated.Drivers.PackagingOutputs do"
  end

  test "imports an exported bundle without executing it and recovers driver artifacts" do
    {:ok, source} =
      Bundle.export_current(
        app_id: "packaging_line",
        workspace: %{open_artifact: {:driver, "packaging_outputs"}, editor_mode: :source}
      )

    assert {:ok, bundle} = Bundle.import(source)

    assert bundle.app_id == "packaging_line"

    assert bundle.workspace == %{
             open_artifact: {:driver, "packaging_outputs"},
             editor_mode: :source
           }

    assert bundle.manifest_module == Ogol.Bundle.PackagingLine
    assert length(bundle.artifacts) == 1

    [artifact] = bundle.artifacts
    assert artifact.kind == :driver
    assert artifact.id == "packaging_outputs"
    assert artifact.module == Ogol.Generated.Drivers.PackagingOutputs
    assert artifact.sync_state == :synced
    assert artifact.digest_match?
    assert artifact.model.label == "Packaging Outputs"
    assert artifact.source =~ "defmodule Ogol.Generated.Drivers.PackagingOutputs do"
  end

  test "imports supported driver artifacts back into the draft store" do
    model =
      DriverDefinition.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Bundle")

    source =
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(model.module_name),
        model
      )

    DriverDraftStore.save_source("packaging_outputs", source, model, :synced, [])

    {:ok, bundle_source} =
      Bundle.export_current(
        app_id: "packaging_line",
        workspace: %{open_artifact: {:driver, "packaging_outputs"}}
      )

    :ok = DriverDraftStore.reset()

    assert {:ok, bundle} = Bundle.import_into_stores(bundle_source)
    assert bundle.app_id == "packaging_line"

    restored = DriverDraftStore.fetch("packaging_outputs")
    assert restored.model.label == "Packaging Outputs Bundle"
    assert restored.sync_state == :synced
    assert restored.source =~ "Packaging Outputs Bundle"
  end

  test "preserves unsupported driver source and imports it source-first" do
    invalid_source = """
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

    DriverDraftStore.save_source(
      "packaging_outputs",
      invalid_source,
      nil,
      :unsupported,
      ["Current source can no longer be represented by the visual editor."]
    )

    {:ok, bundle_source} = Bundle.export_current(app_id: "packaging_line")

    assert {:ok, bundle} = Bundle.import_into_stores(bundle_source)
    [artifact] = bundle.artifacts

    assert artifact.sync_state == :unsupported
    assert artifact.source =~ "%{bad: :type}"

    restored = DriverDraftStore.fetch("packaging_outputs")
    assert restored.sync_state == :unsupported
    assert restored.model == nil
    assert restored.source =~ "%{bad: :type}"
  end

  test "fails clearly when the bundle is missing a manifest" do
    source = """
    defmodule Ogol.Generated.Drivers.PackagingOutputs do
      def hello, do: :world
    end
    """

    assert {:error, :missing_manifest} = Bundle.import(source)
  end
end
