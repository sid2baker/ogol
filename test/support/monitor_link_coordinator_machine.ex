defmodule Ogol.TestSupport.MonitorLinkCoordinatorMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  boundary do
    request(:watch_dependency)
    request(:stop_watching)
    request(:link_dependency)
    request(:unlink_dependency)
    signal(:monitor_down)
    signal(:link_down)
  end

  uses do
    dependency(:clamp)
  end

  states do
    state :idle do
      initial?(true)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :watch_dependency})
      monitor(:clamp, :clamp_watch)
      reply(:ok)
    end

    transition :idle, :idle do
      on({:request, :stop_watching})
      demonitor(:clamp_watch)
      reply(:ok)
    end

    transition :idle, :idle do
      on({:request, :link_dependency})
      link(:clamp)
      reply(:ok)
    end

    transition :idle, :idle do
      on({:request, :unlink_dependency})
      unlink(:clamp)
      reply(:ok)
    end

    transition :idle, :idle do
      on({:monitor, :clamp_watch})
      guard(Ogol.Machine.Helpers.callback(:monitor_from_clamp?))
      signal(:monitor_down)
    end

    transition :idle, :idle do
      on({:link, :exit})
      guard(Ogol.Machine.Helpers.callback(:link_from_clamp?))
      signal(:link_down)
    end
  end

  def monitor_from_clamp?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
    meta[:target] == :clamp and is_pid(meta[:pid])
  end

  def link_from_clamp?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
    meta[:target] == :clamp and is_pid(meta[:pid])
  end

  defmodule Topology do
    @moduledoc false

    use Ogol.Topology

    topology do
      root(:monitor_link_coordinator_machine)
    end

    machines do
      machine(:monitor_link_coordinator_machine, Ogol.TestSupport.MonitorLinkCoordinatorMachine)
      machine(:clamp, Ogol.TestSupport.ClampDependencyMachine)
    end
  end
end
