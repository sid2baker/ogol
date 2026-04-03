defmodule Ogol.Session.WorkspaceLoadScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.Session.RuntimeState
  alias Ogol.Session.State
  alias Ogol.Session.Workspace.LoadedRevision
  alias Ogol.TestSupport.WorkspaceFixture

  setup do
    :ok = Session.reset_runtime()
    :ok = Session.reset_loaded_revision()
    :ok = Session.reset_machines()
    :ok = Session.reset_sequences()
    :ok = Session.reset_topologies()
    :ok = Session.reset_hardware_configs()
    :ok = Session.reset_simulator_configs()
    :ok = Session.reset_hmi_surfaces()
    :ok
  end

  test "loading a revision populates canonical session truth without touching runtime state" do
    assert Session.list_machines() == []
    assert Session.list_sequences() == []
    assert Session.list_topologies() == []
    assert Session.list_hardware_configs() == []
    assert Session.list_simulator_configs() == []
    assert Session.list_hmi_surfaces() == []
    assert Session.loaded_revision() == nil
    assert Session.runtime_state() == %RuntimeState{}
    assert State.artifact_runtime(Session.get_state()) == %{}
    assert Session.runtime_realized?()
    refute Session.runtime_dirty?()

    assert {:ok, revision_file, %{mode: :initial}} = WorkspaceFixture.load_packaging_line!()

    assert revision_file.app_id == "examples"
    assert revision_file.revision == "packaging_line"

    assert Enum.map(Session.list_machines(), & &1.id) == [
             "clamp_station",
             "infeed_conveyor",
             "inspection_cell",
             "inspection_station",
             "packaging_line",
             "palletizer_cell",
             "reject_gate"
           ]

    assert Enum.map(Session.list_topologies(), & &1.id) == ["packaging_line"]
    assert Enum.map(Session.list_hardware_configs(), & &1.id) == ["ethercat"]
    assert Session.list_sequences() == []
    assert Session.list_simulator_configs() == []
    assert Session.list_hmi_surfaces() == []

    assert %LoadedRevision{
             app_id: "examples",
             revision: "packaging_line",
             inventory: inventory
           } = Session.loaded_revision()

    assert inventory == [
             %{
               kind: :hardware_config,
               id: "ethercat",
               module: Ogol.Generated.Hardware.Config.EtherCAT
             },
             %{
               kind: :machine,
               id: "clamp_station",
               module: Ogol.Generated.Machines.ClampStation
             },
             %{
               kind: :machine,
               id: "infeed_conveyor",
               module: Ogol.Generated.Machines.InfeedConveyor
             },
             %{
               kind: :machine,
               id: "inspection_cell",
               module: Ogol.Generated.Machines.InspectionCell
             },
             %{
               kind: :machine,
               id: "inspection_station",
               module: Ogol.Generated.Machines.InspectionStation
             },
             %{
               kind: :machine,
               id: "packaging_line",
               module: Ogol.Generated.Machines.PackagingLine
             },
             %{
               kind: :machine,
               id: "palletizer_cell",
               module: Ogol.Generated.Machines.PalletizerCell
             },
             %{
               kind: :machine,
               id: "reject_gate",
               module: Ogol.Generated.Machines.RejectGate
             },
             %{
               kind: :topology,
               id: "packaging_line",
               module: Ogol.Generated.Topologies.PackagingLine
             }
           ]

    assert Session.runtime_state() == %RuntimeState{}
    assert State.artifact_runtime(Session.get_state()) == %{}
    assert Session.runtime_realized?()
    refute Session.runtime_dirty?()
  end
end
