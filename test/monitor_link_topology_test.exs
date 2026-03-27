defmodule MonitorLinkTopologyTest do
  use ExUnit.Case, async: false

  alias Ogol.TestSupport.MonitorLinkCoordinatorMachine

  test "monitor routes dependency exits back into the coordinator brain" do
    {:ok, topology} = start_topology()
    assert {:ok, :ok} = Ogol.invoke(topology, :watch_dependency)

    dependency_pid = MonitorLinkCoordinatorMachine.Topology.machine_pid(topology, :clamp)
    assert is_pid(dependency_pid)

    Process.exit(dependency_pid, :boom)

    assert_receive {:ogol_signal, :monitor_link_coordinator_machine, :monitor_down, %{}, %{}}
  end

  test "demonitor removes a previously installed monitor" do
    {:ok, topology} = start_topology()
    assert {:ok, :ok} = Ogol.invoke(topology, :watch_dependency)
    assert {:ok, :ok} = Ogol.invoke(topology, :stop_watching)

    dependency_pid = MonitorLinkCoordinatorMachine.Topology.machine_pid(topology, :clamp)
    assert is_pid(dependency_pid)

    Process.exit(dependency_pid, :boom)

    refute_receive {:ogol_signal, :monitor_link_coordinator_machine, :monitor_down, %{}, %{}},
                   50
  end

  test "link routes linked dependency exits back into the coordinator brain" do
    {:ok, topology} = start_topology()
    assert {:ok, :ok} = Ogol.invoke(topology, :link_dependency)

    dependency_pid = MonitorLinkCoordinatorMachine.Topology.machine_pid(topology, :clamp)
    assert is_pid(dependency_pid)

    Process.exit(dependency_pid, :boom)

    assert_receive {:ogol_signal, :monitor_link_coordinator_machine, :link_down, %{}, %{}}
  end

  test "unlink removes a previously installed link" do
    {:ok, topology} = start_topology()
    assert {:ok, :ok} = Ogol.invoke(topology, :link_dependency)
    assert {:ok, :ok} = Ogol.invoke(topology, :unlink_dependency)

    dependency_pid = MonitorLinkCoordinatorMachine.Topology.machine_pid(topology, :clamp)
    assert is_pid(dependency_pid)

    Process.exit(dependency_pid, :boom)

    refute_receive {:ogol_signal, :monitor_link_coordinator_machine, :link_down, %{}, %{}},
                   50
  end

  defp start_topology do
    {:ok, topology} = MonitorLinkCoordinatorMachine.Topology.start_link(signal_sink: self())

    on_exit(fn ->
      catch_exit(GenServer.stop(topology, :shutdown))
      await_registry_clear([:monitor_link_coordinator_machine, :clamp])
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
