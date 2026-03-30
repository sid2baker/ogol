defmodule Ogol.TestSupport.SequenceClampMachine do
  use Ogol.Machine

  machine do
    name(:sequence_clamp)
    meaning("Sequence fixture clamp")
  end

  boundary do
    request(:close)
    request(:open)
    fact(:closed?, :boolean, default: false, public?: true)
    signal(:closed)
  end

  states do
    state :opened do
      initial?(true)
      set_fact(:closed?, false)
    end

    state :closed do
      set_fact(:closed?, true)
      signal(:closed)
    end
  end

  transitions do
    transition :opened, :closed do
      on({:request, :close})
      reply(:ok)
    end

    transition :opened, :opened do
      on({:request, :open})
      reply(:ok)
    end

    transition :closed, :opened do
      on({:request, :open})
      reply(:ok)
    end

    transition :closed, :closed do
      on({:request, :close})
      reply(:ok)
    end
  end
end

defmodule Ogol.TestSupport.SequenceRobotMachine do
  use Ogol.Machine

  machine do
    name(:sequence_robot)
    meaning("Sequence fixture robot")
  end

  boundary do
    request(:pick)
    fact(:homed?, :boolean, default: true, public?: true)
    fact(:at_pick?, :boolean, default: false, public?: true)
    signal(:picked)
  end

  states do
    state :ready do
      initial?(true)
      set_fact(:homed?, true)
      set_fact(:at_pick?, false)
    end

    state :at_pick do
      set_fact(:homed?, true)
      set_fact(:at_pick?, true)
      signal(:picked)
    end
  end

  transitions do
    transition :ready, :at_pick do
      on({:request, :pick})
      reply(:ok)
    end

    transition :at_pick, :at_pick do
      on({:request, :pick})
      reply(:ok)
    end
  end
end

defmodule Ogol.TestSupport.SequenceTopology do
  use Ogol.Topology

  topology do
    root(:clamp)
    meaning("Sequence fixture topology")
  end

  machines do
    machine(:clamp, Ogol.TestSupport.SequenceClampMachine)
    machine(:robot, Ogol.TestSupport.SequenceRobotMachine)
  end
end

defmodule Ogol.TestSupport.SequenceStuckMachine do
  use Ogol.Machine

  machine do
    name(:sequence_stuck)
    meaning("Sequence fixture machine that never becomes ready")
  end

  boundary do
    request(:arm)
    fact(:ready?, :boolean, default: false, public?: true)
  end

  states do
    state :idle do
      initial?(true)
      set_fact(:ready?, false)
    end
  end

  transitions do
    transition :idle, :idle do
      on({:request, :arm})
      reply(:ok)
    end
  end
end

defmodule Ogol.TestSupport.SequenceTimeoutTopology do
  use Ogol.Topology

  topology do
    root(:worker)
    meaning("Sequence timeout topology")
  end

  machines do
    machine(:worker, Ogol.TestSupport.SequenceStuckMachine)
  end
end
