defmodule Ogol.Topology.PlanTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Runtime
  alias Ogol.Session
  alias Ogol.Topology.Plan

  @example_id "pump_skid_commissioning_bench"

  setup do
    :ok = Session.reset_machines()
    :ok = Session.reset_topologies()
    :ok = Session.reset_hardware()
    {:ok, _example, _revision_file, _report} = Session.load_example(@example_id)
    :ok = Session.reset_loaded_revision()
    :ok
  end

  test "build derives required hardware and machine child specs from topology wiring" do
    assert {:ok, %{module: module}} = Runtime.compile(:topology, "pump_skid_bench")
    assert {:ok, %{module: hardware_module}} = Runtime.compile(:hardware, "ethercat")

    topology = apply(module, :__ogol_topology__, [])

    assert {:ok, plan} = Plan.build(topology, hardware: %{"ethercat" => hardware_module})

    assert plan.topology_scope == :pump_skid_bench
    assert plan.required_hardware == %{"ethercat" => hardware_module}
    assert length(plan.machine_specs) == 4

    assert Enum.any?(plan.hardware_children, fn child_spec ->
             child_spec.id == {:ogol_hardware_runtime, "pump_skid_bench"}
           end)

    assert Enum.any?(plan.hardware_children, fn child_spec ->
             child_spec.id == {:ogol_hardware_session, "pump_skid_bench"}
           end)
  end
end
