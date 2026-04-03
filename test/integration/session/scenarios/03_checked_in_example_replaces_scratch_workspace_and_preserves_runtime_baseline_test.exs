defmodule Ogol.Session.CheckedInExampleScratchLoadScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.Session.RuntimeState
  alias Ogol.Session.State
  alias Ogol.Session.Workspace.LoadedRevision

  @example_id "pump_skid_commissioning_bench"

  test "example load replaces a scratch workspace while runtime truth stays stopped" do
    assert Enum.map(Session.list_machines(), & &1.id) == [
             "clamp_station",
             "infeed_conveyor",
             "inspection_cell",
             "inspection_station",
             "packaging_line",
             "palletizer_cell",
             "reject_gate"
           ]

    assert Session.fetch_machine("transfer_pump") == nil
    assert Session.fetch_topology("pump_skid_bench") == nil
    assert Session.list_simulator_configs() == []
    assert Session.loaded_revision() == nil

    assert {:ok, example, revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    assert example.id == @example_id
    assert revision_file.app_id == "ogol_examples"
    assert revision_file.revision == "pump_skid_commissioning_bench"

    assert Enum.map(Session.list_machines(), & &1.id) == [
             "alarm_stack",
             "return_valve",
             "supply_valve",
             "transfer_pump"
           ]

    assert Enum.map(Session.list_topologies(), & &1.id) == ["pump_skid_bench"]
    assert Enum.map(Session.list_hardware_configs(), & &1.id) == ["ethercat"]
    assert Enum.map(Session.list_simulator_configs(), & &1.id) == ["ethercat"]
    assert Enum.map(Session.list_sequences(), & &1.id) == ["pump_skid_commissioning"]

    assert %{sync_state: :synced, model: %{machines: machines}} =
             Session.fetch_topology("pump_skid_bench")

    assert Enum.any?(machines, fn machine ->
             machine.name == "supply_valve" and
               machine.wiring.outputs == %{open_cmd?: :supply_valve_open_cmd} and
               machine.wiring.facts == %{open_fb?: :supply_valve_open_fb}
           end)

    assert Enum.map(Session.list_hmi_surfaces(), & &1.id) == [
             "topology_pump_skid_bench_alarm_stack_station",
             "topology_pump_skid_bench_overview",
             "topology_pump_skid_bench_return_valve_station",
             "topology_pump_skid_bench_supply_valve_station",
             "topology_pump_skid_bench_transfer_pump_station"
           ]

    assert Session.fetch_machine("packaging_line") == nil
    assert Session.fetch_topology("packaging_line") == nil

    assert Session.fetch_machine("transfer_pump").source =~
             "defmodule Ogol.Generated.Machines.TransferPump"

    assert %LoadedRevision{
             app_id: "ogol_examples",
             revision: "pump_skid_commissioning_bench",
             inventory: inventory
           } = Session.loaded_revision()

    assert length(inventory) == 8

    assert Enum.any?(inventory, fn entry ->
             entry.kind == :hardware_config and entry.id == "ethercat" and
               entry.module == Ogol.Generated.Hardware.Config.EtherCAT
           end)

    assert Enum.any?(inventory, fn entry ->
             entry.kind == :simulator_config and entry.id == "ethercat" and
               entry.module == Ogol.Generated.Simulator.Config.EtherCAT
           end)

    assert Enum.any?(inventory, fn entry ->
             entry.kind == :topology and entry.id == "pump_skid_bench" and
               entry.module == Ogol.Generated.Topologies.PumpSkidBench
           end)

    assert Session.runtime_state() == %RuntimeState{}
    assert State.artifact_runtime(Session.get_state()) == %{}
    assert Session.runtime_realized?()
    refute Session.runtime_dirty?()
  end
end
