defmodule Ogol.TestSupport.SafetyDropMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  boundary do
    request(:start)
    command(:start_motor)
    signal(:started)
  end

  states do
    state :idle do
      initial?(true)
    end

    state(:running)
  end

  transitions do
    transition :idle, :running do
      on({:request, :start})
      signal(:started)
      command(:start_motor)
      reply(:ok)
    end
  end

  safety do
    while_in(:running, Ogol.Machine.Helpers.callback(:always_fail))
  end

  def always_fail(_data), do: false
end
