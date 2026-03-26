defmodule CompositeTopologyTest do
  use ExUnit.Case, async: false

  alias Ogol.TestSupport.CompositeParentMachine

  test "topology delegates parent requests and routes child signals back as parent events" do
    {:ok, topology} = CompositeParentMachine.Topology.start_link(signal_sink: self())

    assert :ok = CompositeParentMachine.Topology.request(topology, :start_with_event)
    assert_receive {:ogol_signal, :composite_parent_machine, :cycle_started, %{}, %{}}
  end

  test "topology supports synchronous send_request to child targets" do
    {:ok, topology} = CompositeParentMachine.Topology.start_link(signal_sink: self())

    assert :ok = CompositeParentMachine.Topology.request(topology, :start_with_request)
    assert_receive {:ogol_signal, :composite_parent_machine, :armed_started, %{}, %{}}
  end

  test "child downs are routed back into the parent as events" do
    {:ok, topology} = CompositeParentMachine.Topology.start_link(signal_sink: self())
    child_pid = CompositeParentMachine.Topology.child_pid(topology, :clamp)

    assert is_pid(child_pid)
    Process.exit(child_pid, :boom)

    assert_receive {:ogol_signal, :composite_parent_machine, :child_down, %{}, %{}}
  end

  test "externally injected child event names do not bypass child-origin guards" do
    {:ok, topology} = CompositeParentMachine.Topology.start_link(signal_sink: self())
    brain_pid = CompositeParentMachine.Topology.brain_pid(topology)

    :ok = Ogol.event(brain_pid, :clamp_down)

    refute_receive {:ogol_signal, :composite_parent_machine, :child_down, %{}, %{}}, 50
  end
end
