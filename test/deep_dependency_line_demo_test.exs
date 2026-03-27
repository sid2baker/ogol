defmodule Ogol.Examples.DeepDependencyLineDemoTest do
  use ExUnit.Case, async: false

  alias Ogol.Examples.DeepDependencyLineDemo

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

    assert Enum.any?(Ogol.skills(:left_clamp), &(&1.name == :close))
    assert Enum.any?(Ogol.skills(:right_clamp), &(&1.name == :close))
    assert Enum.any?(Ogol.skills(:pair_station), &(&1.name == :clamp_pair))

    assert {:ok, :ok} = DeepDependencyLineDemo.invoke(demo, :start_cycle)

    assert_receive {:ogol_signal, :deep_dependency_line, :cycle_started, %{}, %{}}
    assert_receive {:ogol_signal, :deep_dependency_line, :kit_loaded, %{}, %{}}
    assert_receive {:ogol_signal, :deep_dependency_line, :cycle_completed, %{}, %{}}

    assert %Ogol.Status{
             machine_id: :deep_dependency_line,
             current_state: :complete,
             outputs: %{busy?: false},
             fields: %{completed_cycles: 1}
           } = Ogol.status(demo.brain)

    assert %Ogol.Status{
             machine_id: :pair_station,
             current_state: :paired,
             outputs: %{paired?: true}
           } = Ogol.status(:pair_station)

    assert %Ogol.Status{
             machine_id: :left_clamp,
             current_state: :closed,
             outputs: %{closed?: true}
           } = Ogol.status(:left_clamp)

    assert %Ogol.Status{
             machine_id: :right_clamp,
             current_state: :closed,
             outputs: %{closed?: true}
           } = Ogol.status(:right_clamp)

    assert {:ok, :ok} = DeepDependencyLineDemo.invoke(demo, :reset_line)
    assert_receive {:ogol_signal, :deep_dependency_line, :line_reset, %{}, %{}}

    assert %Ogol.Status{
             machine_id: :deep_dependency_line,
             current_state: :idle,
             outputs: %{busy?: false},
             fields: %{completed_cycles: 1}
           } = Ogol.status(demo.brain)

    assert %Ogol.Status{
             machine_id: :pair_station,
             current_state: :idle,
             outputs: %{paired?: false}
           } = Ogol.status(:pair_station)
  end
end
