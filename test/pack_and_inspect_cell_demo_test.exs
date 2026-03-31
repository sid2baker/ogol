defmodule Ogol.Examples.PackAndInspectCellDemoTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Master
  alias Ogol.Examples.PackAndInspectCellDemo

  setup do
    _ = PackAndInspectCellDemo.stop()

    on_exit(fn ->
      _ = PackAndInspectCellDemo.stop()
    end)

    :ok
  end

  test "runs a full passing cycle over simulator, master, topology, and coordinated machines" do
    demo = PackAndInspectCellDemo.boot!(signal_sink: self())

    on_exit(fn ->
      PackAndInspectCellDemo.stop(demo)
    end)

    assert is_pid(demo.topology)
    assert is_pid(demo.brain)
    assert is_pid(demo.infeed)
    assert is_pid(demo.clamp)
    assert is_pid(demo.inspector)
    assert is_pid(demo.reject_gate)
    assert %Master.Status{lifecycle: :operational} = Master.status()

    assert PackAndInspectCellDemo.machine_pid(demo, :infeed_conveyor) == demo.infeed
    assert PackAndInspectCellDemo.machine_pid(demo, :clamp_station) == demo.clamp
    assert PackAndInspectCellDemo.machine_pid(demo, :inspection_station) == demo.inspector
    assert PackAndInspectCellDemo.machine_pid(demo, :reject_gate) == demo.reject_gate

    alias Ogol.Examples.PackAndInspectCellDemo.{CellController, InspectionStation}

    assert Enum.any?(CellController.skills(), &(&1.name == :start_cycle))
    assert Enum.any?(InspectionStation.skills(), &(&1.name == :inspect))

    assert PackAndInspectCellDemo.input_snapshot() == %{
             part_at_stop: false,
             clamp_closed: false,
             inspection_ok: false,
             inspection_reject: false
           }

    assert_eventually(fn ->
      PackAndInspectCellDemo.output_snapshot() == %{
        conveyor_run: false,
        clamp_extend: false,
        inspection_active: false,
        reject_gate: false,
        busy_lamp: false,
        good_lamp: false,
        reject_lamp: false
      }
    end)

    :ok = PackAndInspectCellDemo.run_passing_cycle!(demo)

    assert_receive {:ogol_signal, :pack_and_inspect_cell, :cycle_started, %{}, %{}}
    assert_receive {:ogol_signal, :pack_and_inspect_cell, :part_staged, %{}, %{}}
    assert_receive {:ogol_signal, :pack_and_inspect_cell, :clamp_verified, %{}, %{}}
    assert_receive {:ogol_signal, :pack_and_inspect_cell, :cycle_passed, %{}, %{}}

    assert %Ogol.Status{
             machine_id: :pack_and_inspect_cell,
             current_state: :passed,
             outputs: %{busy?: false, pass_ready?: true, reject_active?: false}
           } = PackAndInspectCellDemo.CellController.status(demo.brain)

    {:passed, passed_data} = :sys.get_state(demo.brain)
    assert passed_data.fields.completed_cycles == 1
    assert passed_data.fields.rejected_cycles == 0

    assert PackAndInspectCellDemo.output_snapshot() == %{
             conveyor_run: false,
             clamp_extend: true,
             inspection_active: false,
             reject_gate: false,
             busy_lamp: false,
             good_lamp: true,
             reject_lamp: false
           }

    assert {:ok, :ok} = PackAndInspectCellDemo.invoke(demo, :reset_cell)
    assert_receive {:ogol_signal, :pack_and_inspect_cell, :cell_reset, %{}, %{}}

    assert %Ogol.Status{
             machine_id: :pack_and_inspect_cell,
             current_state: :idle,
             outputs: %{busy?: false, pass_ready?: false, reject_active?: false}
           } = PackAndInspectCellDemo.CellController.status(demo.brain)

    {:idle, idle_data} = :sys.get_state(demo.brain)
    assert idle_data.fields.completed_cycles == 1
    assert idle_data.fields.rejected_cycles == 0

    assert_eventually(fn ->
      PackAndInspectCellDemo.output_snapshot() == %{
        conveyor_run: false,
        clamp_extend: false,
        inspection_active: false,
        reject_gate: false,
        busy_lamp: false,
        good_lamp: false,
        reject_lamp: false
      }
    end)
  end

  test "runs a reject cycle and latches the reject path until reset" do
    demo = PackAndInspectCellDemo.boot!(signal_sink: self())

    on_exit(fn ->
      PackAndInspectCellDemo.stop(demo)
    end)

    :ok = PackAndInspectCellDemo.run_reject_cycle!(demo)

    assert_receive {:ogol_signal, :pack_and_inspect_cell, :cycle_started, %{}, %{}}
    assert_receive {:ogol_signal, :pack_and_inspect_cell, :part_staged, %{}, %{}}
    assert_receive {:ogol_signal, :pack_and_inspect_cell, :clamp_verified, %{}, %{}}
    assert_receive {:ogol_signal, :pack_and_inspect_cell, :cycle_rejected, %{}, %{}}

    assert %Ogol.Status{
             machine_id: :pack_and_inspect_cell,
             current_state: :rejected,
             outputs: %{busy?: false, pass_ready?: false, reject_active?: true}
           } = PackAndInspectCellDemo.CellController.status(demo.brain)

    {:rejected, rejected_data} = :sys.get_state(demo.brain)
    assert rejected_data.fields.completed_cycles == 0
    assert rejected_data.fields.rejected_cycles == 1

    assert %Ogol.Status{
             machine_id: :reject_gate,
             current_state: :latched,
             outputs: %{reject_gate_active?: true}
           } = PackAndInspectCellDemo.RejectGate.status(demo.reject_gate)

    assert PackAndInspectCellDemo.output_snapshot() == %{
             conveyor_run: false,
             clamp_extend: true,
             inspection_active: false,
             reject_gate: true,
             busy_lamp: false,
             good_lamp: false,
             reject_lamp: true
           }

    assert {:ok, :ok} = PackAndInspectCellDemo.invoke(demo, :reset_cell)
    assert_receive {:ogol_signal, :pack_and_inspect_cell, :cell_reset, %{}, %{}}

    assert %Ogol.Status{
             machine_id: :pack_and_inspect_cell,
             current_state: :idle,
             outputs: %{busy?: false, pass_ready?: false, reject_active?: false}
           } = PackAndInspectCellDemo.CellController.status(demo.brain)

    {:idle, idle_data} = :sys.get_state(demo.brain)
    assert idle_data.fields.completed_cycles == 0
    assert idle_data.fields.rejected_cycles == 1

    assert %Ogol.Status{
             machine_id: :reject_gate,
             current_state: :idle,
             outputs: %{reject_gate_active?: false}
           } = PackAndInspectCellDemo.RejectGate.status(demo.reject_gate)

    assert_eventually(fn ->
      PackAndInspectCellDemo.output_snapshot() == %{
        conveyor_run: false,
        clamp_extend: false,
        inspection_active: false,
        reject_gate: false,
        busy_lamp: false,
        good_lamp: false,
        reject_lamp: false
      }
    end)
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, 0) do
    assert fun.()
  end

  defp assert_eventually(fun, attempts) do
    case fun.() do
      true ->
        :ok

      false ->
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
    end
  end
end
