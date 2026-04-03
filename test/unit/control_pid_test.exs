defmodule Ogol.Control.PIDTest do
  use ExUnit.Case, async: true

  alias Ogol.Control.PID
  alias Ogol.Control.PID.Config
  alias Ogol.Control.PID.Memory

  test "step calculates proportional, integral, and derivative terms using elapsed time" do
    config =
      Config.new!(%{
        kp: 2.0,
        ki: 1.0,
        kd: 0.5,
        nominal_dt_ms: 100,
        anti_windup: :none,
        derivative_mode: :error
      })

    memory =
      Memory.new!(%{
        integral: 1.0,
        previous_error: 2.0,
        previous_timestamp: 1_000,
        previous_measurement: 4.0,
        last_output: 0.0
      })

    assert {:ok, result} = PID.step(config, 6.0, 10.0, memory, 1_100)

    assert result.dt_ms == 100
    assert result.error == 4.0
    assert result.proportional == 8.0
    assert result.integral == 1.4
    assert result.derivative == 10.0
    assert result.output == 19.4
    assert result.saturated? == false
    assert result.memory.previous_error == 4.0
    assert result.memory.previous_timestamp == 1_100
    assert result.memory.previous_measurement == 6.0
    assert result.memory.last_output == 19.4
  end

  test "conditional anti-windup prevents integral growth while saturated" do
    config =
      Config.new!(%{
        kp: 10.0,
        ki: 5.0,
        kd: 0.0,
        min_output: 0.0,
        max_output: 10.0,
        nominal_dt_ms: 100,
        anti_windup: :conditional
      })

    memory =
      Memory.new!(%{
        integral: 0.0,
        previous_error: 0.0,
        previous_timestamp: 1_000,
        previous_measurement: 0.0,
        last_output: 0.0
      })

    assert {:ok, result} = PID.step(config, 0.0, 10.0, memory, 1_100)

    assert result.output == 10.0
    assert result.saturated? == true
    assert result.integral == 0.0
  end

  test "derivative on measurement uses previous measurement instead of previous error" do
    config =
      Config.new!(%{
        kp: 0.0,
        ki: 0.0,
        kd: 1.0,
        nominal_dt_ms: 100,
        derivative_mode: :measurement,
        anti_windup: :none
      })

    memory =
      Memory.new!(%{
        integral: 0.0,
        previous_error: 0.0,
        previous_timestamp: 1_000,
        previous_measurement: 2.0,
        last_output: 0.0
      })

    assert {:ok, result} = PID.step(config, 5.0, 10.0, memory, 1_100)

    assert result.derivative == -30.0
    assert result.output == -30.0
  end
end
