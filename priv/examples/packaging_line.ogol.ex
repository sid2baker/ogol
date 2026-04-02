defmodule Ogol.RevisionFile.Examples.PackagingLine do
  @revision %{
    kind: :ogol_revision,
    format: 2,
    app_id: "examples",
    revision: "packaging_line",
    title: "Packaging Line Example",
    exported_at: "2026-04-02T00:00:00Z",
    sources: [
      %{
        kind: :driver,
        id: "packaging_outputs",
        module: Ogol.Generated.Drivers.PackagingOutputs,
        digest: "cd15d49e2cd55e1d1fd0a9f1f053077e5997a627c9651ce6cf2ea7f8a7b13377",
        title: "Packaging Outputs"
      },
      %{
        kind: :hardware_config,
        id: "hardware_config",
        module: Ogol.Generated.Hardware.Config,
        digest: "92f4ca9a15732d7de3881c1ada038d77f655c6c2b5695739706386810e49152d",
        title: "EtherCAT Demo Ring"
      },
      %{
        kind: :machine,
        id: "clamp_station",
        module: Ogol.Generated.Machines.ClampStation,
        digest: "738b8d875c01d5e4d2c9d8d12a9c1422b080f18441509e48d7e1a33799970488",
        title: "Clamp station"
      },
      %{
        kind: :machine,
        id: "infeed_conveyor",
        module: Ogol.Generated.Machines.InfeedConveyor,
        digest: "52a0c4cccb69bfa5709db7b5467526a52f7d2475d30b92ee220302abba549211",
        title: "Infeed conveyor stop"
      },
      %{
        kind: :machine,
        id: "inspection_cell",
        module: Ogol.Generated.Machines.InspectionCell,
        digest: "b93bcfa34ef90ea38a07c261525408eefa855819d41cb0a2d255fa06f272101c",
        title: "Inspection cell coordinator"
      },
      %{
        kind: :machine,
        id: "inspection_station",
        module: Ogol.Generated.Machines.InspectionStation,
        digest: "a04bd08c7d80b7ce1837f9b90186acb91ef28a075251cef94968af8cffd6ca97",
        title: "Inspection station"
      },
      %{
        kind: :machine,
        id: "packaging_line",
        module: Ogol.Generated.Machines.PackagingLine,
        digest: "2dbba66bc5c627459d7d28db49c746668ca33d5fb71b8cf2123e69f4eeea897b",
        title: "Packaging Line coordinator"
      },
      %{
        kind: :machine,
        id: "palletizer_cell",
        module: Ogol.Generated.Machines.PalletizerCell,
        digest: "5c29537b08994a50f90ef8365983f1c0ddee2e5eeeb20ebdd551079deb729933",
        title: "Palletizer cell coordinator"
      },
      %{
        kind: :machine,
        id: "reject_gate",
        module: Ogol.Generated.Machines.RejectGate,
        digest: "f55ceb424cb76e6dd9112e77190c49c4481415d8ce4f1c4785868b081735138b",
        title: "Reject gate actuator"
      },
      %{
        kind: :topology,
        id: "inspection_cell",
        module: Ogol.Generated.Topologies.InspectionCell,
        digest: "c9afdc5e165c50e099aeba4a8de1055e59943c3e73a616c83d29b43ed36cae79",
        title: "Inspection Cell topology"
      },
      %{
        kind: :topology,
        id: "pack_and_inspect_cell",
        module: Ogol.Generated.Topologies.PackAndInspectCell,
        digest: "f8fa9ebc83b164c39602b69e347b96d7eda1e47046477d119c83ad0f2668ed03",
        title: "Pack and inspect cell runtime"
      },
      %{
        kind: :topology,
        id: "packaging_line",
        module: Ogol.Generated.Topologies.PackagingLine,
        digest: "52001de28982f0221ce34063ed961987d2192ca922e4cf5db68c66e84f3c7e8e",
        title: "Packaging Line topology"
      },
      %{
        kind: :topology,
        id: "palletizer_cell",
        module: Ogol.Generated.Topologies.PalletizerCell,
        digest: "20f7ad573044783783c266edc7a1b0c32a73f2b88fbfdf83b81577dac18e6153",
        title: "Palletizer Cell topology"
      }
    ]
  }

  def manifest do
    @revision
  end
end

defmodule Ogol.Generated.Drivers.PackagingOutputs do
  @moduledoc "Generated EtherCAT driver for Packaging Outputs."
  @behaviour EtherCAT.Driver

  @ogol_driver_definition %{
    id: "packaging_outputs",
    label: "Packaging Outputs",
    revision: :any,
    channels: [
      %{default: false, name: :ch1, invert?: false},
      %{default: false, name: :ch2, invert?: false},
      %{default: false, name: :ch3, invert?: false},
      %{default: false, name: :ch4, invert?: false}
    ],
    device_kind: :digital_output,
    product_code: 184_102_994,
    vendor_id: 2
  }

  def definition, do: @ogol_driver_definition

  def identity, do: Ogol.Driver.Runtime.identity(@ogol_driver_definition)

  def signal_model(config, sii_pdo_configs),
    do: Ogol.Driver.Runtime.signal_model(@ogol_driver_definition, config, sii_pdo_configs)

  def encode_signal(signal, config, value),
    do: Ogol.Driver.Runtime.encode_signal(@ogol_driver_definition, signal, config, value)

  def decode_signal(signal, config, raw),
    do: Ogol.Driver.Runtime.decode_signal(@ogol_driver_definition, signal, config, raw)

  def init(config), do: Ogol.Driver.Runtime.init(@ogol_driver_definition, config)

  def project_state(decoded_inputs, prev_state, driver_state, config),
    do:
      Ogol.Driver.Runtime.project_state(
        @ogol_driver_definition,
        decoded_inputs,
        prev_state,
        driver_state,
        config
      )

  def command(command, projected_state, driver_state, config),
    do:
      Ogol.Driver.Runtime.command(
        @ogol_driver_definition,
        command,
        projected_state,
        driver_state,
        config
      )

  def describe(config), do: Ogol.Driver.Runtime.describe(@ogol_driver_definition, config)
end

defmodule Ogol.Generated.Hardware.Config do
  @ogol_hardware_definition %{
    __struct__: Ogol.Hardware.Config,
    id: "ethercat_demo",
    inserted_at: nil,
    label: "EtherCAT Demo Ring",
    meta: %{
      form: %{
        "bind_ip" => "127.0.0.1",
        "domains" => [
          %{
            "cycle_time_us" => "1000",
            "id" => "main",
            "miss_threshold" => "1000",
            "recovery_threshold" => "3"
          }
        ],
        "frame_timeout_ms" => "20",
        "id" => "ethercat_demo",
        "label" => "EtherCAT Demo Ring",
        "scan_poll_ms" => "10",
        "scan_stable_ms" => "20",
        "simulator_ip" => "127.0.0.2",
        "slaves" => [
          %{
            "driver" => "Ogol.Hardware.EtherCAT.Driver.EK1100",
            "health_poll_ms" => "",
            "name" => "coupler",
            "process_data_domain" => "",
            "process_data_mode" => "none",
            "target_state" => "op"
          },
          %{
            "driver" => "Ogol.Hardware.EtherCAT.Driver.EL1809",
            "health_poll_ms" => "",
            "name" => "inputs",
            "process_data_domain" => "main",
            "process_data_mode" => "all",
            "target_state" => "op"
          },
          %{
            "driver" => "Ogol.Hardware.EtherCAT.Driver.EL2809",
            "health_poll_ms" => "",
            "name" => "outputs",
            "process_data_domain" => "main",
            "process_data_mode" => "all",
            "target_state" => "op"
          }
        ]
      }
    },
    protocol: :ethercat,
    spec: %{
      __struct__: Ogol.Hardware.Config.EtherCAT,
      domains: [
        %{
          __struct__: Ogol.Hardware.Config.EtherCAT.Domain,
          cycle_time_us: 1000,
          id: :main,
          miss_threshold: 1000,
          recovery_threshold: 3
        }
      ],
      slaves: [
        %{
          __struct__: EtherCAT.Slave.Config,
          aliases: %{},
          config: %{},
          driver: Ogol.Hardware.EtherCAT.Driver.EK1100,
          health_poll_ms: nil,
          name: :coupler,
          process_data: :none,
          sync: nil,
          target_state: :op
        },
        %{
          __struct__: EtherCAT.Slave.Config,
          aliases: %{},
          config: %{},
          driver: Ogol.Hardware.EtherCAT.Driver.EL1809,
          health_poll_ms: nil,
          name: :inputs,
          process_data: {:all, :main},
          sync: nil,
          target_state: :op
        },
        %{
          __struct__: EtherCAT.Slave.Config,
          aliases: %{},
          config: %{},
          driver: Ogol.Hardware.EtherCAT.Driver.EL2809,
          health_poll_ms: nil,
          name: :outputs,
          process_data: {:all, :main},
          sync: nil,
          target_state: :op
        }
      ],
      timing: %{
        __struct__: Ogol.Hardware.Config.EtherCAT.Timing,
        frame_timeout_ms: 20,
        scan_poll_ms: 10,
        scan_stable_ms: 20
      },
      transport: %{
        __struct__: Ogol.Hardware.Config.EtherCAT.Transport,
        bind_ip: {127, 0, 0, 1},
        mode: :udp,
        primary_interface: nil,
        secondary_interface: nil,
        simulator_ip: {127, 0, 0, 2}
      }
    },
    updated_at: nil
  }

  def definition do
    @ogol_hardware_definition
  end

  def ensure_ready do
    Ogol.Hardware.EtherCAT.Adapter.ensure_ready(definition())
  end

  def stop do
    Ogol.Hardware.EtherCAT.Adapter.stop()
  end
end

defmodule Ogol.Generated.Machines.ClampStation do
  use Ogol.Machine

  machine do
    name(:clamp_station)
    meaning("Clamp station")
  end

  boundary do
    request(:close)
    request(:open)
  end

  states do
    state(:open) do
      initial?(true)
      status("Open")
      meaning("Clamp released")
    end

    state(:closed) do
      status("Closed")
      meaning("Clamp engaged")
    end
  end

  transitions do
    transition(:closed, :open) do
      on({:request, :open})
      meaning("Release the clamp")
      reply(:ok)
    end

    transition(:open, :closed) do
      on({:request, :close})
      meaning("Clamp the staged part")
      reply(:ok)
    end

    transition(:open, :open) do
      on({:request, :open})
      meaning("Keep the clamp released")
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.InfeedConveyor do
  use Ogol.Machine

  machine do
    name(:infeed_conveyor)
    meaning("Infeed conveyor stop")
  end

  boundary do
    request(:feed_part)
    request(:reset)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Idle")
      meaning("Waiting for a part")
    end

    state(:positioned) do
      status("Positioned")
      meaning("Part staged")
    end
  end

  transitions do
    transition(:idle, :idle) do
      on({:request, :reset})
      meaning("Keep the infeed ready")
      reply(:ok)
    end

    transition(:idle, :positioned) do
      on({:request, :feed_part})
      meaning("Stage one part at the clamp stop")
      reply(:ok)
    end

    transition(:positioned, :idle) do
      on({:request, :reset})
      meaning("Clear the staged part")
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.InspectionCell do
  use Ogol.Machine

  machine do
    name(:inspection_cell)
    meaning("Inspection cell coordinator")
  end

  boundary do
    request(:reject)
    request(:reset)
    request(:start)
    signal(:faulted)
    signal(:rejected)
    signal(:started)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Idle")
    end

    state(:faulted) do
      status("Faulted")
    end

    state(:running) do
      status("Running")
    end
  end

  transitions do
    transition(:faulted, :idle) do
      on({:request, :reset})
      reply(:ok)
    end

    transition(:idle, :running) do
      on({:request, :start})
      reply(:ok)
    end

    transition(:running, :faulted) do
      on({:request, :reject})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.InspectionStation do
  use Ogol.Machine

  machine do
    name(:inspection_station)
    meaning("Inspection station")
  end

  boundary do
    request(:pass_part)
    request(:reject_part)
    request(:reset)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Ready")
      meaning("Waiting for inspection input")
    end

    state(:failed) do
      status("Rejected")
      meaning("Part rejected")
    end

    state(:passed) do
      status("Passed")
      meaning("Part accepted")
    end
  end

  transitions do
    transition(:failed, :idle) do
      on({:request, :reset})
      meaning("Prepare for the next inspection")
      reply(:ok)
    end

    transition(:idle, :failed) do
      on({:request, :reject_part})
      meaning("Reject the current part")
      reply(:ok)
    end

    transition(:idle, :idle) do
      on({:request, :reset})
      meaning("Keep the station ready")
      reply(:ok)
    end

    transition(:idle, :passed) do
      on({:request, :pass_part})
      meaning("Accept the current part")
      reply(:ok)
    end

    transition(:passed, :idle) do
      on({:request, :reset})
      meaning("Prepare for the next inspection")
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.PackagingLine do
  use Ogol.Machine

  machine do
    name(:packaging_line)
    meaning("Packaging Line coordinator")
  end

  boundary do
    request(:reset)
    request(:start)
    request(:stop)
    signal(:faulted)
    signal(:started)
    signal(:stopped)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Idle")
    end

    state(:faulted) do
      status("Faulted")
    end

    state(:running) do
      status("Running")
    end
  end

  transitions do
    transition(:faulted, :idle) do
      on({:request, :reset})
      reply(:ok)
    end

    transition(:idle, :running) do
      on({:request, :start})
      reply(:ok)
    end

    transition(:running, :idle) do
      on({:request, :stop})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.PalletizerCell do
  use Ogol.Machine

  machine do
    name(:palletizer_cell)
    meaning("Palletizer cell coordinator")
  end

  boundary do
    request(:arm)
    request(:reset)
    request(:stop)
    signal(:armed)
    signal(:faulted)
    signal(:stopped)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Idle")
    end

    state(:faulted) do
      status("Faulted")
    end

    state(:running) do
      status("Running")
    end
  end

  transitions do
    transition(:faulted, :idle) do
      on({:request, :reset})
      reply(:ok)
    end

    transition(:idle, :running) do
      on({:request, :arm})
      reply(:ok)
    end

    transition(:running, :idle) do
      on({:request, :stop})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.RejectGate do
  use Ogol.Machine

  machine do
    name(:reject_gate)
    meaning("Reject gate actuator")
  end

  boundary do
    request(:reject)
    request(:reset)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Ready")
      meaning("Reject path clear")
    end

    state(:latched) do
      status("Rejecting")
      meaning("Reject gate active")
    end
  end

  transitions do
    transition(:idle, :idle) do
      on({:request, :reset})
      meaning("Keep the reject path clear")
      reply(:ok)
    end

    transition(:idle, :latched) do
      on({:request, :reject})
      meaning("Open the reject path")
      reply(:ok)
    end

    transition(:latched, :idle) do
      on({:request, :reset})
      meaning("Clear the reject latch")
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Topologies.InspectionCell do
  use Ogol.Topology

  topology do
    strategy(:one_for_one)
    meaning("Inspection Cell topology")
  end

  machines do
    machine(:inspection_cell, Ogol.Generated.Machines.InspectionCell,
      restart: :permanent,
      meaning: "Inspection Cell machine"
    )
  end
end

defmodule Ogol.Generated.Topologies.PackAndInspectCell do
  use Ogol.Topology

  topology do
    strategy(:one_for_one)
    meaning("Pack and inspect cell runtime")
  end

  machines do
    machine(:infeed_conveyor, Ogol.Generated.Machines.InfeedConveyor,
      restart: :transient,
      meaning: "Infeed conveyor stop"
    )

    machine(:clamp_station, Ogol.Generated.Machines.ClampStation,
      restart: :transient,
      meaning: "Clamp station"
    )

    machine(:inspection_station, Ogol.Generated.Machines.InspectionStation,
      restart: :transient,
      meaning: "Inspection station"
    )

    machine(:reject_gate, Ogol.Generated.Machines.RejectGate,
      restart: :transient,
      meaning: "Reject gate actuator"
    )
  end
end

defmodule Ogol.Generated.Topologies.PackagingLine do
  use Ogol.Topology

  topology do
    strategy(:one_for_one)
    meaning("Packaging Line topology")
  end

  machines do
    machine(:packaging_line, Ogol.Generated.Machines.PackagingLine,
      restart: :permanent,
      meaning: "Packaging line coordinator"
    )
  end
end

defmodule Ogol.Generated.Topologies.PalletizerCell do
  use Ogol.Topology

  topology do
    strategy(:one_for_one)
    meaning("Palletizer Cell topology")
  end

  machines do
    machine(:palletizer_cell, Ogol.Generated.Machines.PalletizerCell,
      restart: :permanent,
      meaning: "Palletizer Cell machine"
    )
  end
end
