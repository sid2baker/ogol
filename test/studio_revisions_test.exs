defmodule Ogol.Session.RevisionsTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Session.RevisionFile
  alias Ogol.Runtime
  alias Ogol.Studio.Examples
  alias Ogol.Session.Revisions
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.Topology.Registry

  test "deploys immutable revision snapshots without mutating the working drafts" do
    revision_model =
      Session.fetch_hardware_config_model("ethercat")
      |> Map.put(:label, "EtherCAT Revision")

    Session.put_hardware_config(:ethercat, revision_model)

    assert {:ok,
            %Revisions.Revision{
              id: "r1",
              topology_id: "packaging_line",
              source: source
            }} =
             Revisions.deploy_current(app_id: "ogol", topology_id: "packaging_line")

    assert_eventually(fn ->
      assert %{topology_id: :packaging_line} = Registry.active_topology()
    end)

    draft_model =
      Session.fetch_hardware_config_model("ethercat")
      |> Map.put(:label, "EtherCAT Draft")

    Session.put_hardware_config(:ethercat, draft_model)

    assert Session.fetch_hardware_config("ethercat").model.label == "EtherCAT Draft"

    assert {:ok, revision_file} = RevisionFile.import(source)

    assert RevisionFile.artifact(revision_file, :hardware_config, "ethercat").model.label ==
             "EtherCAT Revision"

    assert Session.fetch_hardware_config("ethercat").model.label == "EtherCAT Draft"
  end

  test "exports the watering example even when the machine draft is source-only" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Examples.load_into_workspace("watering_valves")

    draft = Session.fetch_machine("watering_controller")
    assert draft.sync_state == :unsupported
    assert draft.model == nil

    assert {:ok, source} = RevisionFile.export_current(app_id: "ogol_examples")
    assert {:ok, revision_file} = RevisionFile.import(source)

    assert RevisionFile.artifact(revision_file, :machine, "watering_controller").module ==
             Ogol.Generated.Machines.WateringController

    assert RevisionFile.artifact(revision_file, :topology, "watering_system").module ==
             Ogol.Generated.Topologies.WateringSystem

    assert RevisionFile.artifact(revision_file, :hardware_config, "ethercat").module ==
             Ogol.Generated.Hardware.Config.EtherCAT
  end

  test "watering example hardware config source stays loadable through the canonical ethercat module" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Examples.load_into_workspace("watering_valves")

    assert hardware_draft = Session.fetch_hardware_config("ethercat")
    assert hardware_draft.source =~ "ch1: :valve_1_open?"

    assert {:ok, _status} = Runtime.compile(:hardware_config, "ethercat")

    assert {:ok, module} = Runtime.current(:hardware_config, "ethercat")

    assert %Ogol.Hardware.Config.EtherCAT{} = runtime_config = module.definition()
    EthercatHmiFixture.boot_simulator_only!()
    assert {:ok, runtime} = Ogol.Hardware.EtherCAT.Adapter.start_master(runtime_config)
    assert runtime.config.id == "watering_hardware"
    assert :ok = Ogol.Hardware.EtherCAT.Adapter.stop()
  end

  defp assert_eventually(fun, attempts \\ 30)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end
end
