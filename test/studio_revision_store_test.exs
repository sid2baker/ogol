defmodule Ogol.Studio.RevisionStoreTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.RevisionFile
  alias Ogol.Driver.Source, as: DriverSource
  alias Ogol.HMI.HardwareGateway
  alias Ogol.Studio.Examples
  alias Ogol.Studio.RevisionStore
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Topology.Registry

  test "deploys immutable revision snapshots without mutating the working drafts" do
    revision_model =
      DriverSource.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Revision")

    WorkspaceStore.save_driver_source(
      "packaging_outputs",
      DriverSource.to_source(
        DriverSource.module_from_name!(revision_model.module_name),
        revision_model
      ),
      revision_model,
      :synced,
      []
    )

    assert {:ok,
            %RevisionStore.Revision{
              id: "r1",
              topology_id: "packaging_line",
              hardware_config_id: "ethercat_demo",
              source: source
            }} =
             RevisionStore.deploy_current(app_id: "ogol")

    assert %{root: :packaging_line} = Registry.active_topology()
    assert HardwareGateway.ethercat_master_running?()

    draft_model =
      DriverSource.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Draft")

    WorkspaceStore.save_driver_source(
      "packaging_outputs",
      DriverSource.to_source(
        DriverSource.module_from_name!(draft_model.module_name),
        draft_model
      ),
      draft_model,
      :synced,
      []
    )

    assert WorkspaceStore.fetch_driver("packaging_outputs").model.label ==
             "Packaging Outputs Draft"

    assert {:ok, revision_file} = RevisionFile.import(source)

    assert RevisionFile.artifact(revision_file, :driver, "packaging_outputs").model.label ==
             "Packaging Outputs Revision"

    assert WorkspaceStore.fetch_driver("packaging_outputs").model.label ==
             "Packaging Outputs Draft"
  end

  test "exports the watering example even when the machine draft is source-only" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Examples.load_into_workspace("watering_valves")

    draft = WorkspaceStore.fetch_machine("watering_controller")
    assert draft.sync_state == :unsupported
    assert draft.model == nil

    assert {:ok, source} = RevisionFile.export_current(app_id: "ogol_examples")
    assert {:ok, revision_file} = RevisionFile.import(source)

    assert RevisionFile.artifact(revision_file, :machine, "watering_controller").module ==
             Ogol.Generated.Machines.WateringController

    assert RevisionFile.artifact(revision_file, :topology, "watering_system").module ==
             Ogol.Generated.Topologies.WateringSystem

    assert RevisionFile.artifact(revision_file, :hardware_config, "hardware_config").module ==
             Ogol.Generated.HardwareConfig
  end

  test "watering example hardware config source stays loadable even when the config subset cannot recover it" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Examples.load_into_workspace("watering_valves")

    assert hardware_draft = WorkspaceStore.fetch_hardware_config()
    assert hardware_draft.source =~ "ch1: :valve_1_open?"

    assert {:ok, _module} = WorkspaceStore.compile_hardware_config()
    assert {:ok, runtime} = HardwareGateway.activate_runtime_config()
    assert runtime.config.id == "watering_hardware"
  end
end
