defmodule Ogol.TestSupport.TimeoutMachine do
  use Ogol.Machine

  boundary do
    request(:start)
    event(:watchdog)
    signal(:timed_out)
  end

  states do
    state :idle do
      initial?(true)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :start})
      state_timeout(:watchdog, 10)
      state_timeout(:watchdog, 20)
      reply(:ok)
    end

    transition :idle, :idle do
      on({:state_timeout, :watchdog})
      signal(:timed_out)
    end
  end
end
