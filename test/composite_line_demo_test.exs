defmodule Ogol.Examples.CompositeLineDemoTest do
  use ExUnit.Case, async: false

  alias Ogol.Examples.CompositeLineDemo

  test "coordinates feeder, clamp, and inspector dependencies through explicit topology wiring" do
    demo = CompositeLineDemo.boot!(signal_sink: self())

    on_exit(fn ->
      CompositeLineDemo.stop(demo)
    end)

    assert is_pid(demo.topology)
    assert is_pid(demo.brain)
    assert is_pid(demo.feeder)
    assert is_pid(demo.clamp)
    assert is_pid(demo.inspector)
    assert demo.feeder == CompositeLineDemo.machine_pid(demo, :feeder)
    assert demo.clamp == CompositeLineDemo.machine_pid(demo, :clamp)
    assert demo.inspector == CompositeLineDemo.machine_pid(demo, :inspector)
    assert Enum.any?(Ogol.skills(:feeder), &(&1.name == :feed_part))

    assert {:ok, :ok} = CompositeLineDemo.invoke(demo, :start_cycle)

    assert_receive {:ogol_signal, :packaging_line, :cycle_started, %{}, %{}}
    assert_receive {:ogol_signal, :packaging_line, :part_loaded, %{}, %{}}
    assert_receive {:ogol_signal, :packaging_line, :clamp_verified, %{}, %{}}
    assert_receive {:ogol_signal, :packaging_line, :cycle_completed, %{}, %{}}

    {:complete, data_after_cycle} = :sys.get_state(demo.brain)
    assert data_after_cycle.fields.completed_cycles == 1
    assert data_after_cycle.outputs.busy? == false

    assert {:ok, :ok} = CompositeLineDemo.invoke(demo, :release_line)
    assert_receive {:ogol_signal, :packaging_line, :line_released, %{}, %{}}

    {:idle, final_data} = :sys.get_state(demo.brain)
    assert final_data.fields.completed_cycles == 1
    assert final_data.outputs.busy? == false

    assert {:ok, :ok} = CompositeLineDemo.invoke(demo, :release_line)
    assert_receive {:ogol_signal, :packaging_line, :line_released, %{}, %{}}

    assert {:ok, :ok} = CompositeLineDemo.invoke(demo, :start_cycle)
    assert_receive {:ogol_signal, :packaging_line, :cycle_started, %{}, %{}}
    assert_receive {:ogol_signal, :packaging_line, :part_loaded, %{}, %{}}
    assert_receive {:ogol_signal, :packaging_line, :clamp_verified, %{}, %{}}
    assert_receive {:ogol_signal, :packaging_line, :cycle_completed, %{}, %{}}

    {:complete, second_cycle_data} = :sys.get_state(demo.brain)
    assert second_cycle_data.fields.completed_cycles == 2
  end
end
