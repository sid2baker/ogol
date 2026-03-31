defmodule Ogol.Examples.DeepDependencyLineDemoTest do
  use ExUnit.Case, async: false

  alias Ogol.Examples.DeepDependencyLineDemo

  setup do
    stop_running_topology()

    on_exit(fn ->
      stop_running_topology()
    end)

    :ok
  end

  test "runs a deep dependency graph in a flat topology with repeated machine instances" do
    demo = DeepDependencyLineDemo.boot!(signal_sink: self())

    on_exit(fn ->
      DeepDependencyLineDemo.stop(demo)
    end)

    assert is_pid(demo.topology)
    assert is_pid(demo.brain)
    assert is_pid(demo.kit_feeder)
    assert is_pid(demo.pair_station)
    assert is_pid(demo.left_clamp)
    assert is_pid(demo.right_clamp)
    refute demo.left_clamp == demo.right_clamp

    assert demo.left_clamp == DeepDependencyLineDemo.machine_pid(demo, :left_clamp)
    assert demo.right_clamp == DeepDependencyLineDemo.machine_pid(demo, :right_clamp)

    alias Ogol.Examples.DeepDependencyLineDemo.{ClampUnit, PairStation}

    assert Enum.any?(ClampUnit.skills(), &(&1.name == :close))
    assert Enum.any?(PairStation.skills(), &(&1.name == :clamp_pair))

    assert {:ok, :ok} = DeepDependencyLineDemo.invoke(demo, :start_cycle)

    assert_receive {:ogol_signal, :deep_dependency_line, :cycle_started, %{}, %{}}
    assert_receive {:ogol_signal, :deep_dependency_line, :kit_loaded, %{}, %{}}
    assert_receive {:ogol_signal, :deep_dependency_line, :cycle_completed, %{}, %{}}

    alias Ogol.Examples.DeepDependencyLineDemo.LineCoordinator

    assert %Ogol.Status{
             machine_id: :deep_dependency_line,
             current_state: :complete,
             outputs: %{busy?: false},
             fields: %{completed_cycles: 1}
           } = LineCoordinator.status(demo.brain)

    assert %Ogol.Status{
             machine_id: :pair_station,
             current_state: :paired,
             outputs: %{paired?: true}
           } = PairStation.status(:pair_station)

    assert %Ogol.Status{
             machine_id: :left_clamp,
             current_state: :closed,
             outputs: %{closed?: true}
           } = ClampUnit.status(:left_clamp)

    assert %Ogol.Status{
             machine_id: :right_clamp,
             current_state: :closed,
             outputs: %{closed?: true}
           } = ClampUnit.status(:right_clamp)

    assert {:ok, :ok} = DeepDependencyLineDemo.invoke(demo, :reset_line)
    assert_receive {:ogol_signal, :deep_dependency_line, :line_reset, %{}, %{}}

    assert %Ogol.Status{
             machine_id: :deep_dependency_line,
             current_state: :idle,
             outputs: %{busy?: false},
             fields: %{completed_cycles: 1}
           } = LineCoordinator.status(demo.brain)

    assert %Ogol.Status{
             machine_id: :pair_station,
             current_state: :idle,
             outputs: %{paired?: false}
           } = PairStation.status(:pair_station)
  end

  defp stop_running_topology do
    case Ogol.Topology.Registry.whereis(:deep_dependency_line) do
      pid when is_pid(pid) -> DeepDependencyLineDemo.stop(pid)
      _other -> :ok
    end
  end
end
