defmodule OgolEthercatTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Event
  alias Ogol.Hardware.EtherCAT
  alias Ogol.Hardware.EtherCAT.Ref

  test "public EtherCAT runtime events can be observed without fact mappings" do
    ref = %Ref{
      slave: :motor,
      hardware_event: :driver_notice,
      observe_events?: true,
      meta: %{origin: :test}
    }

    assert %Ogol.Runtime.DeliveredEvent{
             family: :hardware,
             name: :driver_notice,
             data: %{event: %{status: :completed}},
             meta: %{bus: :ethercat, origin: :test, kind: :event, slave: :motor}
           } =
             EtherCAT.normalize_message(
               ref,
               Event.internal(:motor, %{status: :completed}, 11, 123)
             )
  end

  test "unobserved EtherCAT public events are ignored" do
    ref = %Ref{slave: :motor}

    assert nil ==
             EtherCAT.normalize_message(
               ref,
               Event.internal(:motor, %{status: :completed}, 11, 123)
             )
  end
end
