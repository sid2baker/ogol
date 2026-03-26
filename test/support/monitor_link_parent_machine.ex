defmodule Ogol.TestSupport.MonitorLinkParentMachine do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  boundary do
    request(:watch_child)
    request(:stop_watching)
    request(:link_child)
    request(:unlink_child)
    signal(:monitor_down)
    signal(:link_down)
  end

  states do
    state :idle do
      initial?(true)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :watch_child})
      monitor(:clamp, :clamp_watch)
      reply(:ok)
    end

    transition :idle, :idle do
      on({:request, :stop_watching})
      demonitor(:clamp_watch)
      reply(:ok)
    end

    transition :idle, :idle do
      on({:request, :link_child})
      link(:clamp)
      reply(:ok)
    end

    transition :idle, :idle do
      on({:request, :unlink_child})
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

  children do
    child(:clamp, Ogol.TestSupport.ClampChildMachine)
  end

  def monitor_from_clamp?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
    meta[:target] == :clamp and is_pid(meta[:pid])
  end

  def link_from_clamp?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
    meta[:target] == :clamp and is_pid(meta[:pid])
  end
end
