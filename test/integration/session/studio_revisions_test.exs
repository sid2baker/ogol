defmodule Ogol.Session.RevisionsTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Session.RevisionFile
  alias Ogol.Runtime
  alias Ogol.Studio.Examples
  alias Ogol.Session.Revisions
  alias Ogol.Session
  alias Ogol.Topology.Registry

  @example_id "pump_skid_commissioning_bench"

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
             Revisions.deploy_current(app_id: "ogol")

    assert_eventually(fn ->
      assert %{topology_scope: :packaging_line} = Registry.active_topology()
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

  test "exports the commissioning example even when the machine draft is source-only" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Examples.load_into_workspace(@example_id)

    draft = Session.fetch_machine("transfer_pump")
    assert draft.sync_state == :unsupported
    assert draft.model == nil

    assert {:ok, source} = RevisionFile.export_current(app_id: "ogol_examples")
    assert {:ok, revision_file} = RevisionFile.import(source)

    assert RevisionFile.artifact(revision_file, :machine, "transfer_pump").module ==
             Ogol.Generated.Machines.TransferPump

    assert RevisionFile.artifact(revision_file, :topology, "pump_skid_bench").module ==
             Ogol.Generated.Topologies.PumpSkidBench

    assert RevisionFile.artifact(revision_file, :hardware_config, "ethercat").module ==
             Ogol.Generated.Hardware.Config.EtherCAT

    assert RevisionFile.artifact(revision_file, :simulator_config, "ethercat").module ==
             Ogol.Generated.Simulator.Config.EtherCAT
  end

  test "commissioning example hardware config source stays loadable through the canonical ethercat module" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Examples.load_into_workspace(@example_id)

    assert hardware_draft = Session.fetch_hardware_config("ethercat")
    assert hardware_draft.source =~ "ch1: :supply_valve_open_cmd"

    assert {:ok, _status} = Runtime.compile(:hardware_config, "ethercat")

    assert {:ok, module} = Runtime.current(:hardware_config, "ethercat")

    assert %Ogol.Hardware.Config.EtherCAT{} = runtime_config = module.definition()
    assert runtime_config.id == "pump_skid_bench"
    assert runtime_config.transport.mode == :raw
    assert runtime_config.transport.primary_interface == "eth0"

    assert Enum.any?(runtime_config.slaves, fn slave ->
             slave.name == :inputs and slave.aliases[:ch1] == :supply_valve_open_fb
           end)

    assert Enum.any?(runtime_config.slaves, fn slave ->
             slave.name == :outputs and slave.aliases[:ch1] == :supply_valve_open_cmd
           end)
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
