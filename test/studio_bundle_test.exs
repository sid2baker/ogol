defmodule Ogol.Session.RevisionFileTest do
  use ExUnit.Case, async: false

  alias Ogol.Driver.Source, as: DriverSource
  alias Ogol.HMI.Surface.Defaults, as: SurfaceDefaults
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore
  alias Ogol.Machine.Contract, as: MachineContract
  alias Ogol.Runtime, as: RuntimeAPI
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Session.RevisionFile
  alias Ogol.Session.Revisions
  alias Ogol.Session
  alias Ogol.Session.Data.SequenceDraft
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.Topology.Registry
  alias Ogol.Topology.Runtime

  setup do
    stop_active_topology()
    _ = RuntimeAPI.reset()
    :ok = Session.reset_drivers()
    :ok = Revisions.reset()
    :ok = Session.reset_loaded_revision()
    :ok = Session.reset_machines()
    :ok = Session.reset_sequences()
    :ok = Session.reset_topologies()
    :ok = Session.replace_hmi_surfaces([])
    :ok = SurfaceRuntimeStore.reset()
    :ok = Session.reset_hardware_config()
    :ok
  end

  defp stop_active_topology do
    case Registry.active_topology() do
      %{pid: pid} when is_pid(pid) ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _reason -> :ok
        end

        await_topology_clear()

      _ ->
        :ok
    end
  end

  defp await_topology_clear(attempts \\ 50)
  defp await_topology_clear(0), do: :ok

  defp await_topology_clear(attempts) do
    case Registry.active_topology() do
      nil ->
        :ok

      _active ->
        Process.sleep(10)
        await_topology_clear(attempts - 1)
    end
  end

  test "exports current studio drafts into a single revision file" do
    seed_hmi_workspace_drafts()

    {:ok, source} =
      RevisionFile.export_current(
        app_id: "packaging_line",
        title: "Packaging Line",
        revision: "r42",
        exported_at: "2026-03-29T15:40:00Z"
      )

    assert source =~ "defmodule Ogol.RevisionFile.PackagingLine.R42 do"
    assert source =~ "kind: :ogol_revision"
    assert source =~ "revision: \"r42\""
    assert source =~ "exported_at: \"2026-03-29T15:40:00Z\""
    assert source =~ "sources: ["
    assert source =~ "digest: "
    assert source =~ "defmodule Ogol.Generated.Drivers.PackagingOutputs do"
    assert source =~ "defmodule Ogol.Generated.Machines.PackagingLine do"
    assert source =~ "defmodule Ogol.Generated.Sequences.PackagingAuto do"
    assert source =~ "defmodule Ogol.Generated.Topologies.PackagingLine do"

    assert source =~
             "module: Ogol.HMI.Surface.StudioDrafts.Topologies.HmiStudioTopology.Overview"

    assert source =~ "defmodule Ogol.Generated.Hardware.Config do"
    assert source =~ "def ensure_ready"
    assert source =~ "def stop"
  end

  test "imports an exported revision file without executing it and recovers studio artifacts" do
    seed_hmi_workspace_drafts()

    {:ok, source} = RevisionFile.export_current(app_id: "packaging_line")

    assert {:ok, revision_file} = RevisionFile.import(source)

    assert revision_file.app_id == "packaging_line"
    assert revision_file.revision == "draft"
    assert revision_file.exported_at == nil
    assert revision_file.warnings == []
    assert revision_file.manifest_module == Ogol.RevisionFile.PackagingLine.Draft
    assert length(revision_file.artifacts) >= 6

    driver_artifact =
      Enum.find(revision_file.artifacts, &(&1.kind == :driver and &1.id == "packaging_outputs"))

    assert driver_artifact.module == Ogol.Generated.Drivers.PackagingOutputs
    assert driver_artifact.sync_state == :synced
    assert driver_artifact.digest_match?
    assert driver_artifact.model.label == "Packaging Outputs"

    surface_artifact =
      Enum.find(
        revision_file.artifacts,
        &(&1.kind == :hmi_surface and &1.id == "topology_hmi_studio_topology_overview")
      )

    assert surface_artifact.module ==
             Ogol.HMI.Surface.StudioDrafts.Topologies.HmiStudioTopology.Overview

    assert surface_artifact.source =~ "use Ogol.HMI.Surface"

    machine_artifact =
      Enum.find(revision_file.artifacts, &(&1.kind == :machine and &1.id == "packaging_line"))

    assert machine_artifact.module == Ogol.Generated.Machines.PackagingLine
    assert machine_artifact.sync_state == :synced
    assert machine_artifact.source =~ "use Ogol.Machine"

    sequence_artifact =
      Enum.find(revision_file.artifacts, &(&1.kind == :sequence and &1.id == "packaging_auto"))

    assert sequence_artifact.module == Ogol.Generated.Sequences.PackagingAuto
    assert sequence_artifact.sync_state == :synced
    assert sequence_artifact.source =~ "use Ogol.Sequence"

    topology_artifact =
      Enum.find(revision_file.artifacts, &(&1.kind == :topology and &1.id == "packaging_line"))

    assert topology_artifact.module == Ogol.Generated.Topologies.PackagingLine
    assert topology_artifact.sync_state == :synced
    assert topology_artifact.source =~ "use Ogol.Topology"

    hardware_artifact =
      Enum.find(
        revision_file.artifacts,
        &(&1.kind == :hardware_config and &1.id == "hardware_config")
      )

    assert hardware_artifact.module == Ogol.Generated.Hardware.Config
    assert hardware_artifact.sync_state == :synced
    assert hardware_artifact.source =~ "def ensure_ready"
  end

  test "imports supported studio artifacts back into the stores" do
    model =
      DriverSource.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Revision")

    source =
      DriverSource.to_source(
        DriverSource.module_from_name!(model.module_name),
        model
      )

    Session.save_driver_source("packaging_outputs", source, model, :synced, [])
    seed_hmi_workspace_drafts()

    {:ok, bundle_source} = RevisionFile.export_current(app_id: "packaging_line")

    :ok = Session.reset_drivers()
    :ok = Session.replace_hmi_surfaces([])
    :ok = SurfaceRuntimeStore.reset()
    :ok = Session.reset_hardware_config()

    assert {:ok, revision_file, %{mode: :initial}} =
             RevisionFile.load_into_workspace(bundle_source)

    assert revision_file.app_id == "packaging_line"

    restored = Session.fetch_driver("packaging_outputs")
    assert restored.model.label == "Packaging Outputs Revision"
    assert restored.sync_state == :synced
    assert restored.source =~ "Packaging Outputs Revision"

    restored_surface = Session.fetch_hmi_surface("topology_hmi_studio_topology_overview")
    assert restored_surface.source =~ "use Ogol.HMI.Surface"

    restored_machine = Session.fetch_machine("packaging_line")
    assert restored_machine.sync_state == :synced
    assert restored_machine.source =~ "defmodule Ogol.Generated.Machines.PackagingLine do"

    restored_sequence = Session.fetch_sequence("packaging_auto")
    assert restored_sequence.sync_state == :synced
    assert restored_sequence.source =~ "defmodule Ogol.Generated.Sequences.PackagingAuto do"

    restored_topology = Session.fetch_topology("packaging_line")
    assert restored_topology.sync_state == :synced
    assert restored_topology.source =~ "defmodule Ogol.Generated.Topologies.PackagingLine do"

    assert {:error, :not_found} = RuntimeAPI.current(:driver, "packaging_outputs")
    assert {:error, :not_found} = RuntimeAPI.current(:machine, "packaging_line")
    assert {:error, :not_found} = RuntimeAPI.current(:topology, "packaging_line")
    assert {:error, :not_found} = RuntimeAPI.current(:sequence, "packaging_auto")
    assert {:error, :not_found} = RuntimeAPI.current(:hardware_config, "hardware_config")

    assert Session.loaded_inventory() != []
  end

  test "revision export stays source-first and derives machine contracts from loaded modules" do
    {:ok, revision_source} = RevisionFile.export_current(app_id: "packaging_line")
    refute revision_source =~ "machine_contract"

    :ok = Session.reset_machines()

    assert {:ok, _revision_file, %{mode: :initial}} =
             RevisionFile.load_into_workspace(revision_source)

    restored_machine = Session.fetch_machine("packaging_line")
    assert restored_machine.sync_state == :synced

    assert {:ok, _status} = RuntimeAPI.compile_machine("packaging_line")
    assert {:ok, module} = RuntimeAPI.current(:machine, "packaging_line")
    assert {:ok, contract} = MachineContract.from_module(module)
    assert contract.machine_id == "packaging_line"
    assert Enum.any?(contract.skills, &(&1.name == "start"))
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

      def identity, do: Ogol.Driver.Runtime.identity(@ogol_driver_definition)
      def signal_model(config, sii_pdo_configs),
        do: Ogol.Driver.Runtime.signal_model(@ogol_driver_definition, config, sii_pdo_configs)
      def encode_signal(signal, config, value),
        do: Ogol.Driver.Runtime.encode_signal(@ogol_driver_definition, signal, config, value)
      def decode_signal(signal, config, raw),
        do: Ogol.Driver.Runtime.decode_signal(@ogol_driver_definition, signal, config, raw)
      def init(config), do: Ogol.Driver.Runtime.init(@ogol_driver_definition, config)
      def project_state(decoded_inputs, prev_state, driver_state, config),
        do: Ogol.Driver.Runtime.project_state(@ogol_driver_definition, decoded_inputs, prev_state, driver_state, config)
      def command(command, projected_state, driver_state, config),
        do: Ogol.Driver.Runtime.command(@ogol_driver_definition, command, projected_state, driver_state, config)
      def describe(config), do: Ogol.Driver.Runtime.describe(@ogol_driver_definition, config)
    end
    """

    Session.save_driver_source(
      "packaging_outputs",
      invalid_source,
      nil,
      :unsupported,
      ["Current source can no longer be represented by the visual editor."]
    )

    {:ok, revision_source} = RevisionFile.export_current(app_id: "packaging_line")

    assert {:ok, revision_file, %{mode: :initial}} =
             RevisionFile.load_into_workspace(revision_source)

    artifact =
      Enum.find(revision_file.artifacts, &(&1.kind == :driver and &1.id == "packaging_outputs"))

    assert artifact.sync_state == :unsupported
    assert artifact.source =~ "%{bad: :type}"

    restored = Session.fetch_driver("packaging_outputs")
    assert restored.sync_state == :unsupported
    assert restored.model == nil
    assert restored.source =~ "%{bad: :type}"
  end

  test "compatible revision reload keeps the loaded structure and makes changed source stale" do
    seed_hmi_workspace_drafts()

    {:ok, original_bundle_source} = RevisionFile.export_current(app_id: "packaging_line")

    assert {:ok, _revision_file, %{mode: :initial}} =
             RevisionFile.load_into_workspace(original_bundle_source)

    assert {:ok, _status} = RuntimeAPI.compile_machine("packaging_line")

    original_runtime_digest =
      case RuntimeAPI.status(:machine, "packaging_line") do
        {:ok, %{source_digest: digest}} -> digest
        {:error, :not_found} -> flunk("expected packaging_line to be loaded")
      end

    updated_bundle_source =
      String.replace(
        original_bundle_source,
        "Packaging Line coordinator",
        "Packaging Line coordinator updated"
      )

    assert {:ok, _revision_file, %{mode: :compatible_reload}} =
             RevisionFile.load_into_workspace(updated_bundle_source)

    draft = Session.fetch_machine("packaging_line")
    assert draft.source =~ "Packaging Line coordinator updated"

    assert {:ok, %{source_digest: ^original_runtime_digest}} =
             RuntimeAPI.status(:machine, "packaging_line")
  end

  test "structural revision changes require force load" do
    seed_hmi_workspace_drafts()

    {:ok, original_bundle_source} = RevisionFile.export_current(app_id: "packaging_line")

    assert {:ok, _revision_file, %{mode: :initial}} =
             RevisionFile.load_into_workspace(original_bundle_source)

    {:ok, example_source} = File.read("priv/examples/watering_valves.ogol.ex")

    assert {:error, {:structural_mismatch, %{added: added, removed: removed}}} =
             RevisionFile.load_into_workspace(example_source)

    assert added != []
    assert removed != []

    assert {:ok, _revision_file, %{mode: :forced_reload}} =
             RevisionFile.load_into_workspace(example_source, force: true)

    assert Session.fetch_machine("watering_controller") != nil
    assert Session.fetch_machine("packaging_line") == nil
    assert {:error, :not_found} = RuntimeAPI.status(:machine, "packaging_line")
  end

  test "fails clearly when the revision file is missing a manifest" do
    source = """
    defmodule Ogol.Generated.Drivers.PackagingOutputs do
      def hello, do: :world
    end
    """

    assert {:error, :missing_manifest} = RevisionFile.import(source)
  end

  test "rejects unsupported revision format versions" do
    source = """
    defmodule Ogol.RevisionFile.BadFormat do
      @revision %{
        kind: :ogol_revision,
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

      def manifest, do: @revision
    end

    defmodule Ogol.Generated.Drivers.PackagingOutputs do
      def hello, do: :world
    end
    """

    assert {:error, {:unsupported_revision_format, 999}} = RevisionFile.import(source)
  end

  test "fails when a source entry is missing required fields" do
    source = """
    defmodule Ogol.RevisionFile.BadSource do
      @revision %{
        kind: :ogol_revision,
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

      def manifest, do: @revision
    end

    defmodule Ogol.Generated.Drivers.PackagingOutputs do
      def hello, do: :world
    end
    """

    assert {:error, {:invalid_manifest, {:source, 0, {:digest, nil}}}} =
             RevisionFile.import(source)
  end

  test "ignores stray top-level modules outside the declared source inventory and records warnings" do
    {:ok, source} = RevisionFile.export_current(app_id: "packaging_line")

    source =
      source <>
        "\n\n" <>
        """
        defmodule Ogol.RevisionFile.StrayHelper do
          def noop, do: :ok
        end
        """

    assert {:ok, revision_file} = RevisionFile.import(source)
    assert revision_file.warnings == [{:ignored_module, Ogol.RevisionFile.StrayHelper}]
  end

  defp seed_hmi_workspace_drafts do
    sequence_source = """
    defmodule Ogol.Generated.Sequences.PackagingAuto do
      use Ogol.Sequence

      alias Ogol.Sequence.Expr
      alias Ogol.Sequence.Ref

      sequence do
        name(:packaging_auto)
        topology(Ogol.Generated.Topologies.PackAndInspectCell)
        meaning("Packaging auto sequence")

        invariant(Expr.not_expr(Ref.topology(:estop)))

        proc :cycle do
          do_skill(:clamp_station, :close)
        end

        run(:cycle)
      end
    end
    """

    {:ok, sequence_model} = SequenceSource.from_source(sequence_source)

    Session.replace_sequences([
      %SequenceDraft{
        id: "packaging_auto",
        source: sequence_source,
        model: sequence_model,
        sync_state: :synced,
        sync_diagnostics: []
      }
    ])

    {:ok, pid} = Runtime.start(HmiStudioTopology.__ogol_topology__())

    Session.replace_hmi_surfaces(
      SurfaceDefaults.drafts_from_topology(HmiStudioTopology.__ogol_topology__())
    )

    if Process.alive?(pid), do: GenServer.stop(pid, :shutdown)
    :ok
  end
end
