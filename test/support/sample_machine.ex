defmodule Ogol.TestSupport.SampleMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  machine do
    name(:sample_machine)
    meaning("Minimal Spark-backed sample machine")
  end

  boundary do
    fact(:guard_closed?, :boolean, default: true)
    event(:sensor_changed)
    request(:start)
    command(:start_motor)
    output(:running?, :boolean, default: false)
    signal(:started)
  end

  memory do
    field(:retry_count, :integer, default: 0)
  end

  states do
    state :idle do
      initial?(true)
      set_output(:running?, false)
    end

    state :running do
      set_output(:running?, true)
    end
  end

  transitions do
    transition :idle, :running do
      on({:request, :start})
      guard(Ogol.Machine.Helpers.callback(:can_start?))
      signal(:started)
      command(:start_motor)
      reply(:ok)
    end
  end

  safety do
    always(Ogol.Machine.Helpers.callback(:machine_safe?))
    while_in(:running, Ogol.Machine.Helpers.callback(:guard_must_stay_closed?))
  end

  def can_start?(_delivered, data), do: Map.get(data.facts, :guard_closed?, false)
  def machine_safe?(_data), do: true
  def guard_must_stay_closed?(_state, data), do: Map.get(data.facts, :guard_closed?, false)
end
