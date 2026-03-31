defmodule Ogol.TestSupport.HmiStudioTopology do
  @moduledoc false

  alias Ogol.TestSupport.SimpleHmiDemo
  alias Ogol.TestSupport.SampleMachine

  use Ogol.Topology

  topology do
    root(:simple_hmi_line)
    meaning("Simple HMI Studio Line")
  end

  machines do
    machine(:simple_hmi_line, SimpleHmiDemo.LineMachine)
    machine(:sample_machine, SampleMachine)
  end
end
