defmodule Ogol.TestSupport.ClampChildMachine do
  use Ogol.Machine

  boundary do
    event(:close_requested)
    request(:arm)
    signal(:ready)
  end

  states do
    state :open do
      initial?(true)
    end

    state :closed do
    end

    state :armed do
      signal(:ready)
    end
  end

  transitions do
    transition :open, :closed do
      on({:event, :close_requested})
    end

    transition :open, :armed do
      on({:request, :arm})
      reply(:ok)
    end
  end
end
