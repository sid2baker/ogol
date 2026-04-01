defmodule OgolEthercatTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Event
  alias Ogol.Hardware.EtherCAT
  alias Ogol.Hardware.EtherCAT.Binding

  test "public EtherCAT runtime events can be observed without fact mappings" do
    binding = %Binding{
      slave: :motor,
      event_name: :driver_notice,
      meta: %{origin: :test}
    }

    assert %Ogol.Runtime.DeliveredEvent{
             family: :hardware,
             name: :driver_notice,
             data: %{event: %{status: :completed}},
             meta: %{bus: :ethercat, origin: :test, kind: :event, slave: :motor}
           } =
             EtherCAT.normalize_message(
               binding,
               Event.internal(:motor, %{status: :completed}, 11, 123)
             )
  end

  test "unobserved EtherCAT public events are ignored" do
    binding = %Binding{slave: :motor}

    assert nil ==
             EtherCAT.normalize_message(
               binding,
               Event.internal(:motor, %{status: :completed}, 11, 123)
             )
  end
end
