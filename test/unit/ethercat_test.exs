defmodule OgolEthercatTest do
  use ExUnit.Case, async: true

  alias EtherCAT.Event
  alias Ogol.TestSupport.GeneratedEtherCATHardware, as: GeneratedEtherCATHardware

  test "public EtherCAT runtime events can be observed without fact mappings" do
    binding = %{
      slave: :motor,
      outputs: %{},
      facts: %{},
      commands: %{},
      event_name: :driver_notice,
      meta: %{origin: :test}
    }

    assert %Ogol.Runtime.DeliveredEvent{
             family: :hardware,
             name: :driver_notice,
             data: %{event: %{status: :completed}},
             meta: %{bus: :ethercat, origin: :test, kind: :event, slave: :motor}
           } =
             GeneratedEtherCATHardware.normalize_message(
               binding,
               Event.internal(:motor, %{status: :completed}, 11, 123)
             )
  end

  test "unobserved EtherCAT public events are ignored" do
    binding = %{slave: :motor, outputs: %{}, facts: %{}, commands: %{}, meta: %{}}

    assert nil ==
             GeneratedEtherCATHardware.normalize_message(
               binding,
               Event.internal(:motor, %{status: :completed}, 11, 123)
             )
  end
end
