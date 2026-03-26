defmodule MonitorLinkTopologyTest do
  use ExUnit.Case, async: false

  alias Ogol.TestSupport.MonitorLinkParentMachine

  test "monitor routes child downs back into the parent brain" do
    {:ok, topology} = MonitorLinkParentMachine.Topology.start_link(signal_sink: self())
    assert :ok = MonitorLinkParentMachine.Topology.request(topology, :watch_child)

    child_pid = MonitorLinkParentMachine.Topology.child_pid(topology, :clamp)
    assert is_pid(child_pid)

    Process.exit(child_pid, :boom)

    assert_receive {:ogol_signal, :monitor_link_parent_machine, :monitor_down, %{}, %{}}
  end

  test "demonitor removes a previously installed monitor" do
    {:ok, topology} = MonitorLinkParentMachine.Topology.start_link(signal_sink: self())
    assert :ok = MonitorLinkParentMachine.Topology.request(topology, :watch_child)
    assert :ok = MonitorLinkParentMachine.Topology.request(topology, :stop_watching)

    child_pid = MonitorLinkParentMachine.Topology.child_pid(topology, :clamp)
    assert is_pid(child_pid)

    Process.exit(child_pid, :boom)

    refute_receive {:ogol_signal, :monitor_link_parent_machine, :monitor_down, %{}, %{}}, 50
  end

  test "link routes linked exits back into the parent brain" do
    {:ok, topology} = MonitorLinkParentMachine.Topology.start_link(signal_sink: self())
    assert :ok = MonitorLinkParentMachine.Topology.request(topology, :link_child)

    child_pid = MonitorLinkParentMachine.Topology.child_pid(topology, :clamp)
    assert is_pid(child_pid)

    Process.exit(child_pid, :boom)

    assert_receive {:ogol_signal, :monitor_link_parent_machine, :link_down, %{}, %{}}
  end

  test "unlink removes a previously installed link" do
    {:ok, topology} = MonitorLinkParentMachine.Topology.start_link(signal_sink: self())
    assert :ok = MonitorLinkParentMachine.Topology.request(topology, :link_child)
    assert :ok = MonitorLinkParentMachine.Topology.request(topology, :unlink_child)

    child_pid = MonitorLinkParentMachine.Topology.child_pid(topology, :clamp)
    assert is_pid(child_pid)

    Process.exit(child_pid, :boom)

    refute_receive {:ogol_signal, :monitor_link_parent_machine, :link_down, %{}, %{}}, 50
  end
end
