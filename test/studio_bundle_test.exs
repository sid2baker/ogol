defmodule Ogol.Studio.BundleTest do
  use ExUnit.Case, async: false

  alias Ogol.HMI.{HardwareConfig, HardwareConfigStore, SurfaceDraftStore}
  alias Ogol.Studio.Bundle
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore
  alias Ogol.Studio.MachineDraftStore

  setup do
    :ok = DriverDraftStore.reset()
    :ok = MachineDraftStore.reset()
    :ok = SurfaceDraftStore.reset()
    :ok = HardwareConfigStore.reset()
    :ok
  end

  test "exports current studio drafts into a single bundle file" do
    :ok =
      HardwareConfigStore.put_config(%HardwareConfig{
        id: "ethercat_demo",
        protocol: :ethercat,
        label: "EtherCAT Demo Ring",
        spec: %{slaves: [], domains: []},
        meta: %{}
      })

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
    assert source =~ "defmodule Ogol.Generated.Machines.PackagingLine do"
    assert source =~ "defmodule Ogol.HMI.Surfaces.StudioDrafts.OperationsOverview do"
    assert source =~ "defmodule Ogol.Generated.HardwareConfigs.EthercatDemo do"
  end

  test "imports an exported bundle without executing it and recovers studio artifacts" do
    :ok =
      HardwareConfigStore.put_config(%HardwareConfig{
        id: "ethercat_demo",
        protocol: :ethercat,
        label: "EtherCAT Demo Ring",
        spec: %{slaves: [], domains: []},
        meta: %{}
      })

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
    assert length(bundle.artifacts) >= 7

    driver_artifact =
      Enum.find(bundle.artifacts, &(&1.kind == :driver and &1.id == "packaging_outputs"))

    assert driver_artifact.module == Ogol.Generated.Drivers.PackagingOutputs
    assert driver_artifact.sync_state == :synced
    assert driver_artifact.digest_match?
    assert driver_artifact.model.label == "Packaging Outputs"

    surface_artifact =
      Enum.find(bundle.artifacts, &(&1.kind == :hmi_surface and &1.id == "operations_overview"))

    assert surface_artifact.module == Ogol.HMI.Surfaces.StudioDrafts.OperationsOverview
    assert surface_artifact.source =~ "use Ogol.HMI.Surface"

    machine_artifact =
      Enum.find(bundle.artifacts, &(&1.kind == :machine and &1.id == "packaging_line"))

    assert machine_artifact.module == Ogol.Generated.Machines.PackagingLine
    assert machine_artifact.sync_state == :synced
    assert machine_artifact.source =~ "use Ogol.Machine"

    hardware_artifact =
      Enum.find(bundle.artifacts, &(&1.kind == :hardware_config and &1.id == "ethercat_demo"))

    assert hardware_artifact.sync_state == :synced
    assert hardware_artifact.model.label == "EtherCAT Demo Ring"
    assert hardware_artifact.source =~ "defmodule Ogol.Generated.HardwareConfigs.EthercatDemo do"
  end

  test "imports supported studio artifacts back into the stores" do
    model =
      DriverDefinition.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Bundle")

    source =
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(model.module_name),
        model
      )

    DriverDraftStore.save_source("packaging_outputs", source, model, :synced, [])

    :ok =
      HardwareConfigStore.put_config(%HardwareConfig{
        id: "ethercat_demo",
        protocol: :ethercat,
        label: "EtherCAT Demo Ring",
        spec: %{slaves: [], domains: []},
        meta: %{}
      })

    {:ok, bundle_source} =
      Bundle.export_current(
        app_id: "packaging_line",
        workspace: %{open_artifact: {:driver, "packaging_outputs"}}
      )

    :ok = DriverDraftStore.reset()
    :ok = SurfaceDraftStore.reset()
    :ok = HardwareConfigStore.reset()

    assert {:ok, bundle} = Bundle.import_into_stores(bundle_source)
    assert bundle.app_id == "packaging_line"

    restored = DriverDraftStore.fetch("packaging_outputs")
    assert restored.model.label == "Packaging Outputs Bundle"
    assert restored.sync_state == :synced
    assert restored.source =~ "Packaging Outputs Bundle"

    restored_surface = SurfaceDraftStore.fetch("operations_overview")
    assert restored_surface.source =~ "use Ogol.HMI.Surface"
    assert restored_surface.compiled_runtime == nil

    restored_machine = MachineDraftStore.fetch("packaging_line")
    assert restored_machine.sync_state == :synced
    assert restored_machine.source =~ "defmodule Ogol.Generated.Machines.PackagingLine do"

    restored_config = HardwareConfigStore.get_config("ethercat_demo")
    assert restored_config.label == "EtherCAT Demo Ring"
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
    artifact = Enum.find(bundle.artifacts, &(&1.kind == :driver and &1.id == "packaging_outputs"))

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
