defmodule Ogol.TestSupport.HibernateMachine do
  use Ogol.Machine

  boundary do
    request(:sleep)
    request(:ping)
  end

  states do
    state :idle do
      initial?(true)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :sleep})
      hibernate()
      reply(:ok)
    end

    transition :idle, :idle do
      on({:request, :ping})
      reply(:pong)
    end
  end
end
