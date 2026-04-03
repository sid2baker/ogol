defmodule Ogol.Topology.PlanTest do
  use ExUnit.Case, async: false

  alias Ogol.Runtime
  alias Ogol.Session
  alias Ogol.Topology.Plan

  setup do
    :ok = Session.reset_machines()
    :ok = Session.reset_topologies()
    :ok = Session.reset_hardware_configs()
    {:ok, _example, _revision_file, _report} = Session.load_example("watering_valves")
    :ok = Session.reset_loaded_revision()
    :ok
  end

  test "build derives required hardware and machine child specs from topology wiring" do
    assert {:ok, %{module: module}} = Runtime.compile(:topology, "watering_system")
    topology = apply(module, :__ogol_topology__, [])
    hardware_config = Session.fetch_hardware_config_model("ethercat")

    assert {:ok, plan} = Plan.build(topology, hardware_configs: %{"ethercat" => hardware_config})

    assert plan.topology_scope == :watering_system
    assert plan.required_hardware == %{"ethercat" => hardware_config}
    assert length(plan.machine_specs) == 1

    assert Enum.any?(plan.hardware_children, fn child_spec ->
             child_spec.id == {:ogol_hardware_runtime, :ethercat}
           end)

    assert Enum.any?(plan.hardware_children, fn child_spec ->
             child_spec.id == {:ogol_hardware_session, :ethercat}
           end)
  end
end
