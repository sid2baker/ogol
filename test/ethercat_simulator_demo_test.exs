defmodule EthercatSimulatorDemoTest do
  use ExUnit.Case, async: false

  alias Ogol.Examples.EthercatSimulatorDemo
  alias Ogol.Examples.EthercatSimulatorDemo.ClampMachine

  setup do
    _ = EthercatSimulatorDemo.stop()

    on_exit(fn ->
      _ = EthercatSimulatorDemo.stop()
    end)

    :ok
  end

  test "demo machine drives simulator outputs and reacts to simulator feedback" do
    %{machine: pid} = EthercatSimulatorDemo.boot!(signal_sink: self())

    assert EthercatSimulatorDemo.snapshot() == %{
             run_lamp: false,
             close_cmd: false,
             closed_fb: false
           }

    assert :ok = Ogol.request(pid, :start_cycle)
    assert_receive {:ogol_signal, :ethercat_simulator_clamp, :waiting_for_clamp, %{}, %{}}

    assert EthercatSimulatorDemo.snapshot() == %{
             run_lamp: true,
             close_cmd: true,
             closed_fb: false
           }

    assert :ok = EthercatSimulatorDemo.set_closed(true)
    assert_receive {:ogol_signal, :ethercat_simulator_clamp, :cycle_started, %{}, %{}}
    assert {:running, _data} = :sys.get_state(pid)
    assert ClampMachine.__ogol_machine__().name == :ethercat_simulator_clamp
  end
end
