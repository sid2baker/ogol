defmodule Ogol.TestSupport.PidControlMachine do
  use Ogol.Machine

  boundary do
    request(:start)
    request(:stop)
    event(:sample)
    fact(:enabled?, :boolean, default: true)
    fact(:setpoint, :float, default: 10.0)
    fact(:process_value, :float, default: 0.0)
    output(:control_output, :float, default: 0.0)
    signal(:pid_tick)
  end

  memory do
    field(:integral, :float, default: 0.0)
    field(:previous_error, :float, default: 0.0)
    field(:previous_timestamp, :integer, default: nil)
    field(:previous_measurement, :float, default: nil)
    field(:last_output, :float, default: 0.0)
  end

  states do
    state :idle do
      initial?(true)
    end

    state :controlling do
      status("Controlling")
    end
  end

  transitions do
    transition :idle, :controlling do
      on({:request, :start})

      foreign(:reset,
        module: Ogol.Control.PIDAction,
        opts: [
          measurement_fact: :process_value,
          setpoint_fact: :setpoint,
          enable_fact: :enabled?,
          output: :control_output,
          reset_output: 0.0
        ]
      )

      state_timeout(:control_tick, 10)
      reply(:ok)
    end

    transition :controlling, :controlling do
      on({:state_timeout, :control_tick})

      foreign(:step,
        module: Ogol.Control.PIDAction,
        opts: [
          measurement_fact: :process_value,
          setpoint_fact: :setpoint,
          enable_fact: :enabled?,
          output: :control_output,
          tick: :control_tick,
          interval_ms: 10,
          disable_mode: :reset,
          reset_output: 0.0,
          config: [
            kp: 2.0,
            ki: 0.0,
            kd: 0.0,
            min_output: 0.0,
            max_output: 100.0,
            nominal_dt_ms: 10
          ]
        ]
      )

      signal(:pid_tick)
    end

    transition :controlling, :idle do
      on({:request, :stop})

      foreign(:reset,
        module: Ogol.Control.PIDAction,
        opts: [
          measurement_fact: :process_value,
          setpoint_fact: :setpoint,
          enable_fact: :enabled?,
          output: :control_output,
          reset_output: 0.0
        ]
      )

      reply(:ok)
    end
  end
end
