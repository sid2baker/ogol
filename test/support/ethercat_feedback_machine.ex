defmodule Ogol.TestSupport.EthercatFeedbackMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  boundary do
    fact(:ready?, :boolean, default: false)
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
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:ready_now?))
      signal(:started)
    end
  end

  def ready_now?(%Ogol.Runtime.DeliveredEvent{meta: meta}, data) do
    meta[:bus] == :ethercat and Map.get(data.facts, :ready?, false)
  end
end
