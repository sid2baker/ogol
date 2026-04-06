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

  test "fact-mapped EtherCAT signal changes preserve fact and channel labels" do
    binding = %{
      slave: :inputs,
      outputs: %{},
      facts: %{green_fb?: :ch4},
      commands: %{},
      meta: %{origin: :test}
    }

    assert %Ogol.Runtime.DeliveredEvent{
             family: :hardware,
             name: :process_image,
             data: %{
               signal: :green_fb?,
               channel: :ch4,
               value: true,
               facts: %{green_fb?: true}
             },
             meta: %{bus: :ethercat, origin: :test, slave: :inputs, signal: :ch4, channel: :ch4}
           } =
             GeneratedEtherCATHardware.normalize_message(
               binding,
               %Event{
                 kind: :signal_changed,
                 slave: :inputs,
                 signal: {:inputs, :ch4},
                 value: true,
                 cycle: 11,
                 updated_at_us: 123
               }
             )
  end
end
