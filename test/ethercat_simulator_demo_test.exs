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

    assert {:ok, :ok} = Ogol.invoke(pid, :start_cycle)
    assert_receive {:ogol_signal, :ethercat_simulator_clamp, :waiting_for_clamp, %{}, %{}}

    assert_eventually(fn ->
      EthercatSimulatorDemo.snapshot() == %{
        run_lamp: true,
        close_cmd: true,
        closed_fb: false
      }
    end)

    assert_eventually(fn ->
      :ok = EthercatSimulatorDemo.set_closed(false)
      Process.sleep(10)
      :ok = EthercatSimulatorDemo.set_closed(true)
      Process.sleep(10)
      match?({:running, _data}, :sys.get_state(pid))
    end)

    assert_receive {:ogol_signal, :ethercat_simulator_clamp, :cycle_started, %{}, %{}}, 500
    assert {:running, _data} = :sys.get_state(pid)
    assert ClampMachine.__ogol_machine__().name == :ethercat_simulator_clamp
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0), do: assert(fun.())

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
