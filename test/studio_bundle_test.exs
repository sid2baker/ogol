defmodule Ogol.Studio.BundleTest do
  use ExUnit.Case, async: false

  alias Ogol.HMI.{HardwareConfigStore, SurfaceDraftStore}
  alias Ogol.HMI.StudioWorkspace
  alias Ogol.Studio.Bundle
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore
  alias Ogol.Studio.MachineDraftStore
  alias Ogol.Studio.SequenceDefinition
  alias Ogol.Studio.SequenceDraftStore
  alias Ogol.Studio.TopologyDraftStore
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.Topology.Runtime

  setup do
    :ok = DriverDraftStore.reset()
    :ok = MachineDraftStore.reset()
    :ok = SequenceDraftStore.reset()
    :ok = TopologyDraftStore.reset()
    :ok = SurfaceDraftStore.reset()
    :ok = HardwareConfigStore.reset()
    :ok
  end

  test "exports current studio drafts into a single bundle file" do
    seed_hmi_workspace_drafts()

    {:ok, source} =
      Bundle.export_current(
        app_id: "packaging_line",
        title: "Packaging Line",
        revision: "r42",
        exported_at: "2026-03-29T15:40:00Z"
      )

    assert source =~ "defmodule Ogol.Bundle.PackagingLine.R42 do"
    assert source =~ "kind: :ogol_revision_bundle"
    assert source =~ "revision: \"r42\""
    assert source =~ "exported_at: \"2026-03-29T15:40:00Z\""
    assert source =~ "sources: ["
    assert source =~ "digest: "
    assert source =~ "defmodule Ogol.Generated.Drivers.PackagingOutputs do"
    assert source =~ "defmodule Ogol.Generated.Machines.PackagingLine do"
    assert source =~ "defmodule Ogol.Generated.Sequences.PackagingAuto do"
    assert source =~ "defmodule Ogol.Generated.Topologies.PackagingLine do"

    assert source =~
             "defmodule Ogol.HMI.Surfaces.StudioDrafts.Topologies.SimpleHmiLine.Overview do"

    refute source =~ "defmodule Ogol.Generated.HardwareConfigs.EthercatDemo do"
  end

  test "imports an exported bundle without executing it and recovers studio artifacts" do
    seed_hmi_workspace_drafts()

    {:ok, source} = Bundle.export_current(app_id: "packaging_line")

    assert {:ok, bundle} = Bundle.import(source)

    assert bundle.app_id == "packaging_line"
    assert bundle.revision == "draft"
    assert bundle.exported_at == nil
    assert bundle.warnings == []
    assert bundle.manifest_module == Ogol.Bundle.PackagingLine.Draft
    assert length(bundle.artifacts) >= 6

    driver_artifact =
      Enum.find(bundle.artifacts, &(&1.kind == :driver and &1.id == "packaging_outputs"))

    assert driver_artifact.module == Ogol.Generated.Drivers.PackagingOutputs
    assert driver_artifact.sync_state == :synced
    assert driver_artifact.digest_match?
    assert driver_artifact.model.label == "Packaging Outputs"

    surface_artifact =
      Enum.find(
        bundle.artifacts,
        &(&1.kind == :hmi_surface and &1.id == "topology_simple_hmi_line_overview")
      )

    assert surface_artifact.module ==
             Ogol.HMI.Surfaces.StudioDrafts.Topologies.SimpleHmiLine.Overview

    assert surface_artifact.source =~ "use Ogol.HMI.Surface"

    machine_artifact =
      Enum.find(bundle.artifacts, &(&1.kind == :machine and &1.id == "packaging_line"))

    assert machine_artifact.module == Ogol.Generated.Machines.PackagingLine
    assert machine_artifact.sync_state == :synced
    assert machine_artifact.source =~ "use Ogol.Machine"

    sequence_artifact =
      Enum.find(bundle.artifacts, &(&1.kind == :sequence and &1.id == "packaging_auto"))

    assert sequence_artifact.module == Ogol.Generated.Sequences.PackagingAuto
    assert sequence_artifact.sync_state == :synced
    assert sequence_artifact.source =~ "use Ogol.Sequence"

    topology_artifact =
      Enum.find(bundle.artifacts, &(&1.kind == :topology and &1.id == "packaging_line"))

    assert topology_artifact.module == Ogol.Generated.Topologies.PackagingLine
    assert topology_artifact.sync_state == :synced
    assert topology_artifact.source =~ "use Ogol.Topology"
    refute Enum.any?(bundle.artifacts, &(&1.kind == :hardware_config))
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
    seed_hmi_workspace_drafts()

    {:ok, bundle_source} = Bundle.export_current(app_id: "packaging_line")

    :ok = DriverDraftStore.reset()
    :ok = SurfaceDraftStore.reset()
    :ok = HardwareConfigStore.reset()

    assert {:ok, bundle} = Bundle.import_into_stores(bundle_source)
    assert bundle.app_id == "packaging_line"

    restored = DriverDraftStore.fetch("packaging_outputs")
    assert restored.model.label == "Packaging Outputs Bundle"
    assert restored.sync_state == :synced
    assert restored.source =~ "Packaging Outputs Bundle"

    restored_surface = SurfaceDraftStore.fetch("topology_simple_hmi_line_overview")
    assert restored_surface.source =~ "use Ogol.HMI.Surface"
    assert restored_surface.compiled_runtime == nil

    restored_machine = MachineDraftStore.fetch("packaging_line")
    assert restored_machine.sync_state == :synced
    assert restored_machine.source =~ "defmodule Ogol.Generated.Machines.PackagingLine do"

    restored_sequence = SequenceDraftStore.fetch("packaging_auto")
    assert restored_sequence.sync_state == :synced
    assert restored_sequence.source =~ "defmodule Ogol.Generated.Sequences.PackagingAuto do"

    restored_topology = TopologyDraftStore.fetch("packaging_line")
    assert restored_topology.sync_state == :synced
    assert restored_topology.source =~ "defmodule Ogol.Generated.Topologies.PackagingLine do"
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

  test "rejects unsupported bundle format versions" do
    source = """
    defmodule Ogol.Bundle.BadFormat do
      @bundle %{
        kind: :ogol_revision_bundle,
        format: 999,
        app_id: "packaging_line",
        revision: "r1",
        sources: [
          %{
            kind: :driver,
            id: "packaging_outputs",
            module: Ogol.Generated.Drivers.PackagingOutputs,
            digest: "sha256:abc"
          }
        ]
      }

      def manifest, do: @bundle
    end

    defmodule Ogol.Generated.Drivers.PackagingOutputs do
      def hello, do: :world
    end
    """

    assert {:error, {:unsupported_bundle_format, 999}} = Bundle.import(source)
  end

  test "fails when a source entry is missing required fields" do
    source = """
    defmodule Ogol.Bundle.BadSource do
      @bundle %{
        kind: :ogol_revision_bundle,
        format: 2,
        app_id: "packaging_line",
        revision: "r1",
        sources: [
          %{
            kind: :driver,
            id: "packaging_outputs",
            module: Ogol.Generated.Drivers.PackagingOutputs
          }
        ]
      }

      def manifest, do: @bundle
    end

    defmodule Ogol.Generated.Drivers.PackagingOutputs do
      def hello, do: :world
    end
    """

    assert {:error, {:invalid_manifest, {:source, 0, {:digest, nil}}}} = Bundle.import(source)
  end

  test "ignores stray top-level modules outside the declared source inventory and records warnings" do
    {:ok, source} = Bundle.export_current(app_id: "packaging_line")

    source =
      source <>
        "\n\n" <>
        """
        defmodule Ogol.Bundle.StrayHelper do
          def noop, do: :ok
        end
        """

    assert {:ok, bundle} = Bundle.import(source)
    assert bundle.warnings == [{:ignored_module, Ogol.Bundle.StrayHelper}]
  end

  defp seed_hmi_workspace_drafts do
    sequence_source = """
    defmodule Ogol.Generated.Sequences.PackagingAuto do
      use Ogol.Sequence

      alias Ogol.Sequence.Expr
      alias Ogol.Sequence.Ref

      sequence do
        name(:packaging_auto)
        topology(Ogol.Generated.Topologies.PackagingLine)
        meaning("Packaging auto sequence")

        invariant(Expr.not_expr(Ref.topology(:estop)))

        proc :cycle do
          do_skill(:packaging_line, :start)
          wait(Ref.status(:packaging_line, :running))
        end

        run(:cycle)
      end
    end
    """

    {:ok, sequence_model} = SequenceDefinition.from_source(sequence_source)

    SequenceDraftStore.replace_drafts([
      %SequenceDraftStore.Draft{
        id: "packaging_auto",
        source: sequence_source,
        model: sequence_model,
        sync_state: :synced,
        sync_diagnostics: []
      }
    ])

    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    {:ok, workspace} = StudioWorkspace.active_workspace()

    Enum.each(workspace.cells, fn cell ->
      SurfaceDraftStore.ensure_definition_draft(cell.surface_id, cell.definition,
        source_module: cell.source_module
      )
    end)

    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    :ok
  end
end
