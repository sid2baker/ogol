defmodule Ogol.TestSupport.CompositeParentMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  boundary do
    request(:start_with_event)
    request(:start_with_request)
    event(:clamp_ready)
    event(:clamp_down)
    signal(:cycle_started)
    signal(:armed_started)
    signal(:child_down)
  end

  states do
    state :idle do
      initial?(true)
    end

    state(:waiting_for_event)
    state(:waiting_for_request)
  end

  transitions do
    transition :idle, :waiting_for_event do
      on({:request, :start_with_event})
      send_event(:clamp, :close_requested)
      reply(:ok)
    end

    transition :idle, :waiting_for_request do
      on({:request, :start_with_request})
      send_request(:clamp, :arm)
      reply(:ok)
    end

    transition :waiting_for_event, :idle do
      on({:event, :clamp_ready})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_child?))
      signal(:cycle_started)
    end

    transition :waiting_for_request, :idle do
      on({:event, :clamp_ready})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_child?))
      signal(:armed_started)
    end

    transition :idle, :idle do
      on({:event, :clamp_down})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_child?))
      signal(:child_down)
    end

    transition :waiting_for_event, :idle do
      on({:event, :clamp_down})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_child?))
      signal(:child_down)
    end

    transition :waiting_for_request, :idle do
      on({:event, :clamp_down})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_child?))
      signal(:child_down)
    end
  end

  children do
    child(:clamp, Ogol.TestSupport.ClampChildMachine,
      state_bindings: [closed: :clamp_ready],
      signal_bindings: [ready: :clamp_ready],
      down_binding: :clamp_down
    )
  end

  def from_clamp_child?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
    meta[:origin] == :child and meta[:child] == :clamp and is_pid(meta[:child_pid])
  end
end
