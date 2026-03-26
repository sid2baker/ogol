defmodule Ogol.TestSupport.FactPatchMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  boundary do
    fact(:ready?, :boolean, default: false)
    event(:sensor_changed)
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
      on({:event, :sensor_changed})
      guard(Ogol.Machine.Helpers.callback(:ready_now?))
      signal(:started)
    end
  end

  def ready_now?(_delivered, data), do: Map.get(data.facts, :ready?, false)
end
