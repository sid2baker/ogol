defmodule Ogol.TestSupport.DuplicateReplyMachine do
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
      reply(:ok)
      reply(:again)
    end
  end
end
