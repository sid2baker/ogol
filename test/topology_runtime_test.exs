defmodule TopologyRuntimeTest do
  use ExUnit.Case, async: false

  test "topology starts a single live instance for each machine module" do
    topology_module = unique_module("TwoMachineTopology")

    Code.compile_string("""
    defmodule #{inspect(topology_module)} do
      use Ogol.Topology

      topology do
        strategy(:one_for_one)
      end

      machines do
        machine(:primary_clamp, Ogol.TestSupport.ClampDependencyMachine)
        machine(:backup_robot, Ogol.TestSupport.SequenceRobotMachine)
      end
    end
    """)

    {:ok, topology} = topology_module.start_link()

    on_exit(fn ->
      if Process.alive?(topology) do
        try do
          GenServer.stop(topology, :shutdown)
        catch
          :exit, _reason -> :ok
        end
      end

      await_registry_clear([:primary_clamp, :backup_robot])
    end)

    primary_pid = topology_module.machine_pid(topology, :primary_clamp)
    backup_pid = topology_module.machine_pid(topology, :backup_robot)

    assert is_pid(primary_pid)
    assert is_pid(backup_pid)
    refute primary_pid == backup_pid

    assert Enum.any?(Ogol.TestSupport.ClampDependencyMachine.skills(), &(&1.name == :arm))

    assert %Ogol.Status{machine_id: :primary_clamp} =
             Ogol.TestSupport.ClampDependencyMachine.status(:primary_clamp)

    assert %Ogol.Status{machine_id: :backup_robot} =
             Ogol.TestSupport.SequenceRobotMachine.status(:backup_robot)
  end

  defp unique_module(prefix) do
    Module.concat([Ogol, TestSupport, :"#{prefix}#{System.unique_integer([:positive])}"])
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
