defmodule Ogol.TestSupport.AuthoredEthercatBoundMachine do
  use Ogol.Machine

  machine do
    name(:authored_ethercat_bound_machine)
  end

  boundary do
    request(:start)
    command(:start_motor)
    output(:running?, :boolean, default: false)
  end

  states do
    state :idle do
      initial?(true)
      set_output(:running?, false)
    end

    state :running do
      set_output(:running?, true)
    end
  end

  transitions do
    transition :idle, :running do
      on({:request, :start})
      command(:start_motor)
      reply(:ok)
    end
  end
end
