defmodule Ogol.RevisionFile.OgolExamples.PumpSkidCommissioningBench do
  @revision %{
    kind: :ogol_revision,
    format: 2,
    app_id: "ogol_examples",
    revision: "pump_skid_commissioning_bench",
    title: "Pump Skid Commissioning Bench",
    exported_at: "2026-04-03T00:00:00Z",
    sources: [
      %{
        kind: :hardware_config,
        id: "ethercat",
        module: Ogol.Generated.Hardware.Config.EtherCAT,
        digest: "0000000000000000000000000000000000000000000000000000000000000001",
        title: "Pump skid EtherCAT bench"
      },
      %{
        kind: :simulator_config,
        id: "ethercat",
        module: Ogol.Generated.Simulator.Config.EtherCAT,
        digest: "0000000000000000000000000000000000000000000000000000000000000002",
        title: "Pump skid EtherCAT simulator"
      },
      %{
        kind: :machine,
        id: "supply_valve",
        module: Ogol.Generated.Machines.SupplyValve,
        digest: "0000000000000000000000000000000000000000000000000000000000000003",
        title: "Supply isolation valve"
      },
      %{
        kind: :machine,
        id: "return_valve",
        module: Ogol.Generated.Machines.ReturnValve,
        digest: "0000000000000000000000000000000000000000000000000000000000000004",
        title: "Return isolation valve"
      },
      %{
        kind: :machine,
        id: "transfer_pump",
        module: Ogol.Generated.Machines.TransferPump,
        digest: "0000000000000000000000000000000000000000000000000000000000000005",
        title: "Transfer pump starter"
      },
      %{
        kind: :machine,
        id: "alarm_stack",
        module: Ogol.Generated.Machines.AlarmStack,
        digest: "0000000000000000000000000000000000000000000000000000000000000006",
        title: "Alarm stack"
      },
      %{
        kind: :sequence,
        id: "pump_skid_commissioning",
        module: Ogol.Generated.Sequences.PumpSkidCommissioning,
        digest: "0000000000000000000000000000000000000000000000000000000000000007",
        title: "Pump skid commissioning cycle"
      },
      %{
        kind: :topology,
        id: "pump_skid_bench",
        module: Ogol.Generated.Topologies.PumpSkidBench,
        digest: "0000000000000000000000000000000000000000000000000000000000000008",
        title: "Pump skid commissioning topology"
      }
    ]
  }

  def manifest do
    @revision
  end
end

defmodule Ogol.Generated.Hardware.Config.EtherCAT do
  @ogol_hardware_definition %Ogol.Hardware.Config.EtherCAT{
    transport: %Ogol.Hardware.Config.EtherCAT.Transport{
      mode: :raw,
      bind_ip: nil,
      primary_interface: "eth0",
      secondary_interface: nil
    },
    timing: %Ogol.Hardware.Config.EtherCAT.Timing{
      scan_stable_ms: 20,
      scan_poll_ms: 10,
      frame_timeout_ms: 20
    },
    id: "pump_skid_bench",
    label: "Pump skid EtherCAT bench",
    domains: [
      %Ogol.Hardware.Config.EtherCAT.Domain{
        id: :main,
        cycle_time_us: 1000,
        miss_threshold: 1000,
        recovery_threshold: 3
      }
    ],
    slaves: [
      %EtherCAT.Slave.Config{
        name: :coupler,
        driver: Ogol.Hardware.EtherCAT.Driver.EK1100,
        config: %{},
        aliases: %{},
        process_data: :none,
        target_state: :op,
        sync: nil,
        health_poll_ms: 250
      },
      %EtherCAT.Slave.Config{
        name: :inputs,
        driver: Ogol.Hardware.EtherCAT.Driver.EL1809,
        config: %{},
        aliases: %{
          ch1: :supply_valve_open_fb,
          ch2: :return_valve_open_fb,
          ch3: :transfer_pump_running_fb,
          ch4: :stacklight_green_fb,
          ch5: :stacklight_red_fb,
          ch6: :horn_fb
        },
        process_data: {:all, :main},
        target_state: :op,
        sync: nil,
        health_poll_ms: 250
      },
      %EtherCAT.Slave.Config{
        name: :outputs,
        driver: Ogol.Hardware.EtherCAT.Driver.EL2809,
        config: %{},
        aliases: %{
          ch1: :supply_valve_open_cmd,
          ch2: :return_valve_open_cmd,
          ch3: :transfer_pump_run_cmd,
          ch4: :stacklight_green_cmd,
          ch5: :stacklight_red_cmd,
          ch6: :horn_cmd
        },
        process_data: {:all, :main},
        target_state: :op,
        sync: nil,
        health_poll_ms: 250
      }
    ],
    inserted_at: 1_775_180_000_000,
    updated_at: 1_775_180_000_000,
    meta: %{}
  }

  def definition do
    @ogol_hardware_definition
  end
end

defmodule Ogol.Generated.Simulator.Config.EtherCAT do
  def simulator_opts do
    [
      devices: [
        EtherCAT.Simulator.Slave.from_driver(Ogol.Hardware.EtherCAT.Driver.EK1100, name: :coupler),
        EtherCAT.Simulator.Slave.from_driver(Ogol.Hardware.EtherCAT.Driver.EL1809, name: :inputs),
        EtherCAT.Simulator.Slave.from_driver(Ogol.Hardware.EtherCAT.Driver.EL2809, name: :outputs)
      ],
      backend: {:udp, %{host: {127, 0, 0, 2}, port: 0}},
      topology: :linear,
      connections: [
        %{source: {:outputs, :ch1}, target: {:inputs, :ch1}},
        %{source: {:outputs, :ch2}, target: {:inputs, :ch2}},
        %{source: {:outputs, :ch3}, target: {:inputs, :ch3}},
        %{source: {:outputs, :ch4}, target: {:inputs, :ch4}},
        %{source: {:outputs, :ch5}, target: {:inputs, :ch5}},
        %{source: {:outputs, :ch6}, target: {:inputs, :ch6}}
      ]
    ]
  end
end

defmodule Ogol.Generated.Machines.SupplyValve do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  machine do
    name(:supply_valve)
    meaning("Supply isolation valve with wired open feedback")
  end

  boundary do
    request(:open)
    request(:close)
    request(:reset_fault)
    fact(:open_fb?, :boolean, default: false, public?: true)
    output(:open_cmd?, :boolean, default: false, public?: true)
    signal(:opened)
    signal(:closed)
    signal(:faulted)
  end

  states do
    state :closed do
      initial?(true)
      status("Closed")
      set_output(:open_cmd?, false)
    end

    state :opening do
      status("Opening")
      set_output(:open_cmd?, true)
      state_timeout(:open_timeout, 750)
    end

    state :open do
      status("Open")
      set_output(:open_cmd?, true)
    end

    state :closing do
      status("Closing")
      set_output(:open_cmd?, false)
      state_timeout(:close_timeout, 750)
    end

    state :faulted do
      status("Faulted")
      set_output(:open_cmd?, false)
    end
  end

  transitions do
    transition :closed, :open do
      on({:request, :open})
      guard(Ogol.Machine.Helpers.callback(:feedback_open_now?))
      signal(:opened)
      reply(:ok)
    end

    transition :closed, :opening do
      on({:request, :open})
      reply(:ok)
    end

    transition :open, :open do
      on({:request, :open})
      reply(:ok)
    end

    transition :opening, :open do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:feedback_open_now?))
      signal(:opened)
    end

    transition :opening, :faulted do
      on({:state_timeout, :open_timeout})
      signal(:faulted)
    end

    transition :open, :closed do
      on({:request, :close})
      guard(Ogol.Machine.Helpers.callback(:feedback_closed_now?))
      signal(:closed)
      reply(:ok)
    end

    transition :open, :closing do
      on({:request, :close})
      reply(:ok)
    end

    transition :closed, :closed do
      on({:request, :close})
      reply(:ok)
    end

    transition :closing, :closed do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:feedback_closed_now?))
      signal(:closed)
    end

    transition :closing, :faulted do
      on({:state_timeout, :close_timeout})
      signal(:faulted)
    end

    transition :faulted, :closed do
      on({:request, :reset_fault})
      reply(:ok)
    end
  end

  def feedback_open_now?(_delivered, data), do: Map.get(data.facts, :open_fb?, false)
  def feedback_closed_now?(_delivered, data), do: not Map.get(data.facts, :open_fb?, false)
end

defmodule Ogol.Generated.Machines.ReturnValve do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  machine do
    name(:return_valve)
    meaning("Return isolation valve with wired open feedback")
  end

  boundary do
    request(:open)
    request(:close)
    request(:reset_fault)
    fact(:open_fb?, :boolean, default: false, public?: true)
    output(:open_cmd?, :boolean, default: false, public?: true)
    signal(:opened)
    signal(:closed)
    signal(:faulted)
  end

  states do
    state :closed do
      initial?(true)
      status("Closed")
      set_output(:open_cmd?, false)
    end

    state :opening do
      status("Opening")
      set_output(:open_cmd?, true)
      state_timeout(:open_timeout, 750)
    end

    state :open do
      status("Open")
      set_output(:open_cmd?, true)
    end

    state :closing do
      status("Closing")
      set_output(:open_cmd?, false)
      state_timeout(:close_timeout, 750)
    end

    state :faulted do
      status("Faulted")
      set_output(:open_cmd?, false)
    end
  end

  transitions do
    transition :closed, :open do
      on({:request, :open})
      guard(Ogol.Machine.Helpers.callback(:feedback_open_now?))
      signal(:opened)
      reply(:ok)
    end

    transition :closed, :opening do
      on({:request, :open})
      reply(:ok)
    end

    transition :open, :open do
      on({:request, :open})
      reply(:ok)
    end

    transition :opening, :open do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:feedback_open_now?))
      signal(:opened)
    end

    transition :opening, :faulted do
      on({:state_timeout, :open_timeout})
      signal(:faulted)
    end

    transition :open, :closed do
      on({:request, :close})
      guard(Ogol.Machine.Helpers.callback(:feedback_closed_now?))
      signal(:closed)
      reply(:ok)
    end

    transition :open, :closing do
      on({:request, :close})
      reply(:ok)
    end

    transition :closed, :closed do
      on({:request, :close})
      reply(:ok)
    end

    transition :closing, :closed do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:feedback_closed_now?))
      signal(:closed)
    end

    transition :closing, :faulted do
      on({:state_timeout, :close_timeout})
      signal(:faulted)
    end

    transition :faulted, :closed do
      on({:request, :reset_fault})
      reply(:ok)
    end
  end

  def feedback_open_now?(_delivered, data), do: Map.get(data.facts, :open_fb?, false)
  def feedback_closed_now?(_delivered, data), do: not Map.get(data.facts, :open_fb?, false)
end

defmodule Ogol.Generated.Machines.TransferPump do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  machine do
    name(:transfer_pump)
    meaning("Transfer pump starter with wired running feedback")
  end

  boundary do
    request(:start)
    request(:stop)
    request(:reset_fault)
    fact(:running_fb?, :boolean, default: false, public?: true)
    output(:run_cmd?, :boolean, default: false, public?: true)
    signal(:started)
    signal(:stopped)
    signal(:faulted)
  end

  states do
    state :stopped do
      initial?(true)
      status("Stopped")
      set_output(:run_cmd?, false)
    end

    state :starting do
      status("Starting")
      set_output(:run_cmd?, true)
      state_timeout(:start_timeout, 750)
    end

    state :running do
      status("Running")
      set_output(:run_cmd?, true)
    end

    state :stopping do
      status("Stopping")
      set_output(:run_cmd?, false)
      state_timeout(:stop_timeout, 750)
    end

    state :faulted do
      status("Faulted")
      set_output(:run_cmd?, false)
    end
  end

  transitions do
    transition :stopped, :running do
      on({:request, :start})
      guard(Ogol.Machine.Helpers.callback(:running_feedback_now?))
      signal(:started)
      reply(:ok)
    end

    transition :stopped, :starting do
      on({:request, :start})
      reply(:ok)
    end

    transition :running, :running do
      on({:request, :start})
      reply(:ok)
    end

    transition :starting, :running do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:running_feedback_now?))
      signal(:started)
    end

    transition :starting, :faulted do
      on({:state_timeout, :start_timeout})
      signal(:faulted)
    end

    transition :running, :stopped do
      on({:request, :stop})
      guard(Ogol.Machine.Helpers.callback(:stopped_feedback_now?))
      signal(:stopped)
      reply(:ok)
    end

    transition :running, :stopping do
      on({:request, :stop})
      reply(:ok)
    end

    transition :stopped, :stopped do
      on({:request, :stop})
      reply(:ok)
    end

    transition :stopping, :stopped do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:stopped_feedback_now?))
      signal(:stopped)
    end

    transition :stopping, :faulted do
      on({:state_timeout, :stop_timeout})
      signal(:faulted)
    end

    transition :faulted, :stopped do
      on({:request, :reset_fault})
      reply(:ok)
    end
  end

  def running_feedback_now?(_delivered, data), do: Map.get(data.facts, :running_fb?, false)
  def stopped_feedback_now?(_delivered, data), do: not Map.get(data.facts, :running_fb?, false)
end

defmodule Ogol.Generated.Machines.AlarmStack do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  machine do
    name(:alarm_stack)
    meaning("Three-output alarm stack with wired feedback for each indication")
  end

  boundary do
    request(:show_running)
    request(:show_fault)
    request(:clear)
    fact(:green_fb?, :boolean, default: false, public?: true)
    fact(:red_fb?, :boolean, default: false, public?: true)
    fact(:horn_fb?, :boolean, default: false, public?: true)
    output(:green_cmd?, :boolean, default: false, public?: true)
    output(:red_cmd?, :boolean, default: false, public?: true)
    output(:horn_cmd?, :boolean, default: false, public?: true)
    signal(:running_indicated)
    signal(:fault_indicated)
    signal(:cleared)
    signal(:faulted)
  end

  states do
    state :clear do
      initial?(true)
      status("Clear")
      set_output(:green_cmd?, false)
      set_output(:red_cmd?, false)
      set_output(:horn_cmd?, false)
    end

    state :running_pending do
      status("Showing Running")
      set_output(:green_cmd?, true)
      set_output(:red_cmd?, false)
      set_output(:horn_cmd?, false)
      state_timeout(:running_timeout, 750)
    end

    state :running do
      status("Running Indication")
      set_output(:green_cmd?, true)
      set_output(:red_cmd?, false)
      set_output(:horn_cmd?, false)
    end

    state :fault_pending do
      status("Showing Fault")
      set_output(:green_cmd?, false)
      set_output(:red_cmd?, true)
      set_output(:horn_cmd?, true)
      state_timeout(:fault_timeout, 750)
    end

    state :fault do
      status("Fault Indication")
      set_output(:green_cmd?, false)
      set_output(:red_cmd?, true)
      set_output(:horn_cmd?, true)
    end

    state :clearing do
      status("Clearing")
      set_output(:green_cmd?, false)
      set_output(:red_cmd?, false)
      set_output(:horn_cmd?, false)
      state_timeout(:clear_timeout, 750)
    end

    state :faulted do
      status("Faulted")
      set_output(:green_cmd?, false)
      set_output(:red_cmd?, false)
      set_output(:horn_cmd?, false)
    end
  end

  transitions do
    transition :clear, :running do
      on({:request, :show_running})
      guard(Ogol.Machine.Helpers.callback(:running_feedback_now?))
      signal(:running_indicated)
      reply(:ok)
    end

    transition :clear, :running_pending do
      on({:request, :show_running})
      reply(:ok)
    end

    transition :running_pending, :running do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:running_feedback_now?))
      signal(:running_indicated)
    end

    transition :running_pending, :faulted do
      on({:state_timeout, :running_timeout})
      signal(:faulted)
    end

    transition :running, :running do
      on({:request, :show_running})
      reply(:ok)
    end

    transition :clear, :fault do
      on({:request, :show_fault})
      guard(Ogol.Machine.Helpers.callback(:fault_feedback_now?))
      signal(:fault_indicated)
      reply(:ok)
    end

    transition :running, :fault do
      on({:request, :show_fault})
      guard(Ogol.Machine.Helpers.callback(:fault_feedback_now?))
      signal(:fault_indicated)
      reply(:ok)
    end

    transition :clear, :fault_pending do
      on({:request, :show_fault})
      reply(:ok)
    end

    transition :running, :fault_pending do
      on({:request, :show_fault})
      reply(:ok)
    end

    transition :fault_pending, :fault do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:fault_feedback_now?))
      signal(:fault_indicated)
    end

    transition :fault_pending, :faulted do
      on({:state_timeout, :fault_timeout})
      signal(:faulted)
    end

    transition :fault, :fault do
      on({:request, :show_fault})
      reply(:ok)
    end

    transition :running, :clear do
      on({:request, :clear})
      guard(Ogol.Machine.Helpers.callback(:clear_feedback_now?))
      signal(:cleared)
      reply(:ok)
    end

    transition :fault, :clear do
      on({:request, :clear})
      guard(Ogol.Machine.Helpers.callback(:clear_feedback_now?))
      signal(:cleared)
      reply(:ok)
    end

    transition :running, :clearing do
      on({:request, :clear})
      reply(:ok)
    end

    transition :fault, :clearing do
      on({:request, :clear})
      reply(:ok)
    end

    transition :clearing, :clear do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:clear_feedback_now?))
      signal(:cleared)
    end

    transition :clearing, :faulted do
      on({:state_timeout, :clear_timeout})
      signal(:faulted)
    end

    transition :faulted, :clear do
      on({:request, :clear})
      reply(:ok)
    end
  end

  def running_feedback_now?(_delivered, data) do
    Map.get(data.facts, :green_fb?, false) and
      not Map.get(data.facts, :red_fb?, false) and
      not Map.get(data.facts, :horn_fb?, false)
  end

  def fault_feedback_now?(_delivered, data) do
    not Map.get(data.facts, :green_fb?, false) and
      Map.get(data.facts, :red_fb?, false) and
      Map.get(data.facts, :horn_fb?, false)
  end

  def clear_feedback_now?(_delivered, data) do
    not Map.get(data.facts, :green_fb?, false) and
      not Map.get(data.facts, :red_fb?, false) and
      not Map.get(data.facts, :horn_fb?, false)
  end
end

defmodule Ogol.Generated.Sequences.PumpSkidCommissioning do
  use Ogol.Sequence

  alias Ogol.Sequence.Ref

  sequence do
    name(:pump_skid_commissioning)
    topology(Ogol.Generated.Topologies.PumpSkidBench)
    meaning("Commissioning cycle over a real EtherCAT loopback bench")

    proc :line_up do
      do_skill(:supply_valve, :open)
      wait(Ref.signal(:supply_valve, :opened), signal?: true, timeout: 2_000, fail: "supply valve feedback did not go high")
      do_skill(:return_valve, :open)
      wait(Ref.signal(:return_valve, :opened), signal?: true, timeout: 2_000, fail: "return valve feedback did not go high")
    end

    proc :run_transfer do
      do_skill(:transfer_pump, :start)
      wait(Ref.signal(:transfer_pump, :started), signal?: true, timeout: 2_000, fail: "pump did not report running")
      do_skill(:alarm_stack, :show_running)
      wait(Ref.signal(:alarm_stack, :running_indicated), signal?: true, timeout: 2_000, fail: "running stack indication did not arrive")
    end

    proc :trip_alarm do
      do_skill(:alarm_stack, :show_fault)
      wait(Ref.signal(:alarm_stack, :fault_indicated), signal?: true, timeout: 2_000, fail: "fault stack indication did not arrive")
    end

    proc :shutdown do
      do_skill(:transfer_pump, :stop)
      wait(Ref.signal(:transfer_pump, :stopped), signal?: true, timeout: 2_000, fail: "pump did not stop")
      do_skill(:alarm_stack, :clear)
      wait(Ref.signal(:alarm_stack, :cleared), signal?: true, timeout: 2_000, fail: "alarm stack did not clear")
      do_skill(:return_valve, :close)
      wait(Ref.signal(:return_valve, :closed), signal?: true, timeout: 2_000, fail: "return valve did not close")
      do_skill(:supply_valve, :close)
      wait(Ref.signal(:supply_valve, :closed), signal?: true, timeout: 2_000, fail: "supply valve did not close")
    end

    run(:line_up, meaning: "Open the fluid path")
    run(:run_transfer, meaning: "Start the transfer path")
    run(:trip_alarm, meaning: "Exercise the fault indication")
    run(:shutdown, meaning: "Return the skid to safe idle")
  end
end

defmodule Ogol.Generated.Topologies.PumpSkidBench do
  use Ogol.Topology

  topology do
    strategy(:rest_for_one)
    meaning("Pump skid commissioning topology over wired EtherCAT IO")
  end

  machines do
    machine(
      :supply_valve,
      Ogol.Generated.Machines.SupplyValve,
      meaning: "Supply valve actuator",
      wiring: [
        outputs: [open_cmd?: :supply_valve_open_cmd],
        facts: [open_fb?: :supply_valve_open_fb]
      ]
    )

    machine(
      :return_valve,
      Ogol.Generated.Machines.ReturnValve,
      meaning: "Return valve actuator",
      wiring: [
        outputs: [open_cmd?: :return_valve_open_cmd],
        facts: [open_fb?: :return_valve_open_fb]
      ]
    )

    machine(
      :transfer_pump,
      Ogol.Generated.Machines.TransferPump,
      meaning: "Transfer pump motor starter",
      wiring: [
        outputs: [run_cmd?: :transfer_pump_run_cmd],
        facts: [running_fb?: :transfer_pump_running_fb]
      ]
    )

    machine(
      :alarm_stack,
      Ogol.Generated.Machines.AlarmStack,
      meaning: "Alarm stack outputs",
      wiring: [
        outputs: [
          green_cmd?: :stacklight_green_cmd,
          red_cmd?: :stacklight_red_cmd,
          horn_cmd?: :horn_cmd
        ],
        facts: [
          green_fb?: :stacklight_green_fb,
          red_fb?: :stacklight_red_fb,
          horn_fb?: :horn_fb
        ]
      ]
    )
  end
end
