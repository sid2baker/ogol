defmodule Ogol.TestSupport.MissingReplyMachine do
  use Ogol.Machine

  boundary do
    request(:start)
  end

  states do
    state :idle do
      initial?(true)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :start})
    end
  end
end
