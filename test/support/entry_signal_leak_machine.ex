defmodule Ogol.TestSupport.EntrySignalLeakMachine do
  use Ogol.Machine

  boundary do
    request(:start)
    signal(:entered)
  end

  states do
    state :idle do
      initial?(true)
    end

    state :running do
      signal(:entered)
    end
  end

  transitions do
    transition :idle, :running do
      on({:request, :start})
    end
  end
end
