defmodule Ogol.TestSupport.StopMachine do
  use Ogol.Machine

  boundary do
    request(:stop_now)
    request(:stop_and_reply)
  end

  states do
    state :idle do
      initial?(true)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :stop_now})
      stop(:shutdown)
    end

    transition :idle, :idle do
      on({:request, :stop_and_reply})
      reply(:ok)
      stop(:shutdown)
    end
  end
end
