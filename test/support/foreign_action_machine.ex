defmodule Ogol.TestSupport.ForeignActionMachine do
  use Ogol.Machine

  boundary do
    request(:start)
    signal(:foreign_ran)
  end

  memory do
    field(:status, :atom, default: :idle)
  end

  states do
    state :idle do
      initial?(true)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :start})

      foreign(:mark_and_signal,
        module: Ogol.TestSupport.TestForeignAction,
        opts: [field: :status, signal: :foreign_ran]
      )

      reply(:ok)
    end
  end
end
