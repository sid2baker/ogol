defmodule Ogol.TestSupport.CompositeCoordinatorMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  boundary do
    request(:start_with_event)
    request(:start_with_request)
    event(:clamp_ready)
    event(:dependency_down)
    signal(:cycle_started)
    signal(:armed_started)
    signal(:dependency_down)
  end

  uses do
    dependency(:clamp, skills: [:close_requested, :arm], signals: [:ready])
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
      invoke(:clamp, :close_requested)
      reply(:ok)
    end

    transition :idle, :waiting_for_request do
      on({:request, :start_with_request})
      invoke(:clamp, :arm)
      reply(:ok)
    end

    transition :waiting_for_event, :idle do
      on({:event, :clamp_ready})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_dependency?))
      signal(:cycle_started)
    end

    transition :waiting_for_request, :idle do
      on({:event, :clamp_ready})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_dependency?))
      signal(:armed_started)
    end

    transition :idle, :idle do
      on({:event, :dependency_down})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_dependency?))
      signal(:dependency_down)
    end

    transition :waiting_for_event, :idle do
      on({:event, :dependency_down})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_dependency?))
      signal(:dependency_down)
    end

    transition :waiting_for_request, :idle do
      on({:event, :dependency_down})
      guard(Ogol.Machine.Helpers.callback(:from_clamp_dependency?))
      signal(:dependency_down)
    end
  end

  def from_clamp_dependency?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
    meta[:origin] == :dependency and meta[:dependency] == :clamp and
      is_pid(meta[:dependency_pid])
  end

  defmodule Topology do
    @moduledoc false

    use Ogol.Topology

    topology do
      root(:composite_coordinator_machine)
    end

    machines do
      machine(:composite_coordinator_machine, Ogol.TestSupport.CompositeCoordinatorMachine)
      machine(:clamp, Ogol.TestSupport.ClampDependencyMachine)
    end

    observations do
      observe_state(:clamp, :closed, as: :clamp_ready)
      observe_signal(:clamp, :ready, as: :clamp_ready)
      observe_down(:clamp, as: :dependency_down)
    end
  end
end
