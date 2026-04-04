defmodule Ogol.Session.RevisionsTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session.RevisionFile
  alias Ogol.Runtime
  alias Ogol.Studio.Examples
  alias Ogol.Session.Revisions
  alias Ogol.Session
  alias Ogol.Topology.Registry

  @example_id "pump_skid_commissioning_bench"

  test "deploys immutable revision snapshots without mutating the working drafts" do
    revision_model =
      Session.fetch_hardware_model("ethercat")
      |> Map.put(:label, "EtherCAT Revision")

    Session.put_hardware(:ethercat, revision_model)

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
      Session.fetch_hardware_model("ethercat")
      |> Map.put(:label, "EtherCAT Draft")

    Session.put_hardware(:ethercat, draft_model)

    assert Session.fetch_hardware("ethercat").model.label == "EtherCAT Draft"

    assert {:ok, revision_file} = RevisionFile.import(source)

    assert RevisionFile.artifact(revision_file, :hardware, "ethercat").model.label ==
             "EtherCAT Revision"

    assert Session.fetch_hardware("ethercat").model.label == "EtherCAT Draft"
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

    assert RevisionFile.artifact(revision_file, :hardware, "ethercat").module ==
             Ogol.Generated.Hardware.EtherCAT

    assert RevisionFile.artifact(revision_file, :simulator_config, "ethercat").module ==
             Ogol.Generated.Simulator.Config.EtherCAT
  end

  test "commissioning example hardware source stays loadable through the canonical ethercat module" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Examples.load_into_workspace(@example_id)

    assert hardware_draft = Session.fetch_hardware("ethercat")
    assert hardware_draft.source =~ "defmodule Ogol.Generated.Hardware.EtherCAT"

    assert {:ok, _status} = Runtime.compile(:hardware, "ethercat")

    assert {:ok, module} = Runtime.current(:hardware, "ethercat")

    assert %Ogol.Hardware.EtherCAT{} = runtime_config = module.hardware()
    assert runtime_config.id == "pump_skid_bench"
    assert runtime_config.transport.mode == :raw
    assert runtime_config.transport.primary_interface == "eth0"

    assert Enum.any?(runtime_config.slaves, &(&1.name == :inputs))
    assert Enum.any?(runtime_config.slaves, &(&1.name == :outputs))
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
