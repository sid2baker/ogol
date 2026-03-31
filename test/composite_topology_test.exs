defmodule CompositeTopologyTest do
  use ExUnit.Case, async: false

  alias Ogol.TestSupport.CompositeCoordinatorMachine
  alias Ogol.TestSupport.MonitorLinkCoordinatorMachine

  test "topology delegates coordinator requests and routes dependency signals back as coordinator events" do
    {:ok, topology} = start_topology()

    assert {:ok, :ok} = Ogol.Runtime.Delivery.invoke(topology, :start_with_event)
    assert_receive {:ogol_signal, :composite_coordinator_machine, :cycle_started, %{}, %{}}
  end

  test "topology supports authored invoke to dependency skills" do
    {:ok, topology} = start_topology()

    assert {:ok, :ok} = Ogol.Runtime.Delivery.invoke(topology, :start_with_request)
    assert_receive {:ogol_signal, :composite_coordinator_machine, :armed_started, %{}, %{}}
  end

  test "dependency downs are routed back into the coordinator as events" do
    {:ok, topology} = start_topology()
    dependency_pid = CompositeCoordinatorMachine.Topology.machine_pid(topology, :clamp)

    assert is_pid(dependency_pid)
    Process.exit(dependency_pid, :boom)

    assert_receive {:ogol_signal, :composite_coordinator_machine, :dependency_down, %{}, %{}},
                   250
  end

  test "externally injected dependency event names do not bypass dependency-origin guards" do
    {:ok, topology} = start_topology()
    brain_pid = CompositeCoordinatorMachine.Topology.brain_pid(topology)

    :ok = Ogol.Runtime.Delivery.event(brain_pid, :dependency_down)

    refute_receive {:ogol_signal, :composite_coordinator_machine, :dependency_down, %{}, %{}},
                   50
  end

  test "only one topology may run at a time" do
    {:ok, topology} = start_topology()

    assert {:error, {:topology_already_running, active}} =
             MonitorLinkCoordinatorMachine.Topology.start()

    assert active.root == :composite_coordinator_machine
    assert active.module == CompositeCoordinatorMachine.Topology
    assert active.pid == topology
  end

  defp start_topology do
    {:ok, topology} = CompositeCoordinatorMachine.Topology.start_link(signal_sink: self())

    on_exit(fn ->
      catch_exit(GenServer.stop(topology, :shutdown))
      await_registry_clear([:composite_coordinator_machine, :clamp])
    end)

    {:ok, topology}
  end

  defp await_registry_clear(names, attempts \\ 50)

  defp await_registry_clear(_names, 0), do: :ok

  defp await_registry_clear(names, attempts) do
    if Enum.all?(names, &(Ogol.Topology.Registry.whereis(&1) == nil)) do
      :ok
    else
      Process.sleep(10)
      await_registry_clear(names, attempts - 1)
    end
  end
end
