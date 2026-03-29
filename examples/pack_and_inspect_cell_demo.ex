defmodule Ogol.Examples.PackAndInspectCellDemo do
  @moduledoc """
  Hardware-backed multi-machine demo over the stock EtherCAT coupler/input/output
  ring.

  The cell models a common automation task:

  - feed one part into the station
  - clamp it
  - wait for an inspection result
  - either accept the cycle or reject the part

  The hardware is intentionally simple:

  - coupler
  - one EL1809 input bank
  - one EL2809 output bank

  This demo is useful for testing the full stack:

  - EtherCAT simulator
  - EtherCAT master in operational mode
  - topology runtime
  - multiple coordinated machines
  - HMI runtime surfaces for an active topology

  In IEx:

      iex -S mix phx.server
      demo = Ogol.Examples.PackAndInspectCellDemo.boot!(signal_sink: self())
      {:ok, :ok} = Ogol.Examples.PackAndInspectCellDemo.invoke(demo, :start_cycle)
      Ogol.Examples.PackAndInspectCellDemo.set_input(:part_at_stop, true)
      Ogol.Examples.PackAndInspectCellDemo.set_input(:clamp_closed, true)
      Ogol.Examples.PackAndInspectCellDemo.set_input(:inspection_ok, true)
      flush()
      Ogol.Examples.PackAndInspectCellDemo.snapshot(demo)
      {:ok, :ok} = Ogol.Examples.PackAndInspectCellDemo.invoke(demo, :reset_cell)
      Ogol.Examples.PackAndInspectCellDemo.stop(demo)
  """

  alias EtherCAT.Backend
  alias EtherCAT.Driver.{EK1100, EL1809, EL2809}
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias EtherCAT.Simulator.Slave, as: SimulatorSlave
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware.EtherCAT.Ref
  alias Ogol.Topology.Registry

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}
  @scan_stable_ms 20
  @scan_poll_ms 10
  @frame_timeout_ms 20
  @await_attempts 80

  @machines [
    :pack_and_inspect_cell,
    :infeed_conveyor,
    :clamp_station,
    :inspection_station,
    :reject_gate
  ]

  @type demo :: %{
          topology: pid(),
          brain: pid(),
          infeed: pid() | nil,
          clamp: pid() | nil,
          inspector: pid() | nil,
          reject_gate: pid() | nil,
          simulator_port: :inet.port_number()
        }

  defmodule CellTopology do
    @moduledoc false

    use Ogol.Topology

    topology do
      root(:pack_and_inspect_cell)
    end

    machines do
      machine(:pack_and_inspect_cell, Ogol.Examples.PackAndInspectCellDemo.CellController)
      machine(:infeed_conveyor, Ogol.Examples.PackAndInspectCellDemo.InfeedConveyor)
      machine(:clamp_station, Ogol.Examples.PackAndInspectCellDemo.ClampStation)
      machine(:inspection_station, Ogol.Examples.PackAndInspectCellDemo.InspectionStation)
      machine(:reject_gate, Ogol.Examples.PackAndInspectCellDemo.RejectGate)
    end

    observations do
      observe_signal(:infeed_conveyor, :part_arrived, as: :part_arrived)
      observe_signal(:clamp_station, :clamp_closed, as: :clamp_ready)
      observe_signal(:inspection_station, :inspection_passed, as: :inspection_passed)
      observe_signal(:inspection_station, :inspection_failed, as: :inspection_failed)
      observe_down(:infeed_conveyor, as: :dependency_down)
      observe_down(:clamp_station, as: :dependency_down)
      observe_down(:inspection_station, as: :dependency_down)
      observe_down(:reject_gate, as: :dependency_down)
    end
  end

  defmodule InfeedConveyor do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:infeed_conveyor)
      meaning("Feeds one part into the stop sensor and then holds position")
    end

    boundary do
      fact(:part_at_stop?, :boolean, default: false, public?: true)
      request(:feed_part)
      request(:reset)
      output(:conveyor_run?, :boolean, default: false, public?: true)
      signal(:part_arrived)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:conveyor_run?, false)
      end

      state :feeding do
        set_output(:conveyor_run?, true)
      end

      state :positioned do
        set_output(:conveyor_run?, false)
        signal(:part_arrived)
      end
    end

    transitions do
      transition :idle, :feeding do
        on({:request, :feed_part})
        reply(:ok)
      end

      transition :positioned, :positioned do
        on({:request, :feed_part})
        reenter?(true)
        reply(:ok)
      end

      transition :feeding, :positioned do
        on({:hardware, :process_image})
        guard(Ogol.Machine.Helpers.callback(:part_detected?))
      end

      transition :feeding, :idle do
        on({:request, :reset})
        reply(:ok)
      end

      transition :positioned, :idle do
        on({:request, :reset})
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :reset})
        reply(:ok)
      end
    end

    def part_detected?(%Ogol.Runtime.DeliveredEvent{meta: meta}, data) do
      meta[:bus] == :ethercat and Map.get(data.facts, :part_at_stop?, false)
    end
  end

  defmodule ClampStation do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:clamp_station)
      meaning("Closes a simple clamp and waits for the closed feedback input")
    end

    boundary do
      fact(:clamp_closed?, :boolean, default: false, public?: true)
      request(:close)
      request(:open)
      output(:clamp_extend?, :boolean, default: false, public?: true)
      signal(:clamp_closed)
    end

    states do
      state :open do
        initial?(true)
        set_output(:clamp_extend?, false)
      end

      state :closing do
        set_output(:clamp_extend?, true)
      end

      state :closed do
        set_output(:clamp_extend?, true)
        signal(:clamp_closed)
      end
    end

    transitions do
      transition :open, :closing do
        on({:request, :close})
        reply(:ok)
      end

      transition :closed, :closed do
        on({:request, :close})
        reenter?(true)
        reply(:ok)
      end

      transition :closing, :closed do
        on({:hardware, :process_image})
        guard(Ogol.Machine.Helpers.callback(:closed_feedback?))
      end

      transition :closing, :open do
        on({:request, :open})
        reply(:ok)
      end

      transition :closed, :open do
        on({:request, :open})
        reply(:ok)
      end

      transition :open, :open do
        on({:request, :open})
        reply(:ok)
      end
    end

    def closed_feedback?(%Ogol.Runtime.DeliveredEvent{meta: meta}, data) do
      meta[:bus] == :ethercat and Map.get(data.facts, :clamp_closed?, false)
    end
  end

  defmodule InspectionStation do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:inspection_station)
      meaning("Waits for a pass or reject sensor and exposes the inspection result")
    end

    boundary do
      fact(:inspection_ok?, :boolean, default: false, public?: true)
      fact(:inspection_reject?, :boolean, default: false, public?: true)
      request(:inspect)
      request(:reset)
      output(:inspection_active?, :boolean, default: false, public?: true)
      signal(:inspection_passed)
      signal(:inspection_failed)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:inspection_active?, false)
      end

      state :inspecting do
        set_output(:inspection_active?, true)
      end

      state :passed do
        set_output(:inspection_active?, false)
        signal(:inspection_passed)
      end

      state :failed do
        set_output(:inspection_active?, false)
        signal(:inspection_failed)
      end
    end

    transitions do
      transition :idle, :inspecting do
        on({:request, :inspect})
        reply(:ok)
      end

      transition :inspecting, :passed do
        on({:hardware, :process_image})
        guard(Ogol.Machine.Helpers.callback(:passed?))
      end

      transition :inspecting, :failed do
        on({:hardware, :process_image})
        guard(Ogol.Machine.Helpers.callback(:failed?))
      end

      transition :passed, :idle do
        on({:request, :reset})
        reply(:ok)
      end

      transition :failed, :idle do
        on({:request, :reset})
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :reset})
        reply(:ok)
      end
    end

    def passed?(%Ogol.Runtime.DeliveredEvent{meta: meta}, data) do
      meta[:bus] == :ethercat and Map.get(data.facts, :inspection_ok?, false)
    end

    def failed?(%Ogol.Runtime.DeliveredEvent{meta: meta}, data) do
      meta[:bus] == :ethercat and Map.get(data.facts, :inspection_reject?, false)
    end
  end

  defmodule RejectGate do
    @moduledoc false

    use Ogol.Machine

    machine do
      name(:reject_gate)
      meaning("Latches a reject output until the controller resets the cell")
    end

    boundary do
      request(:reject)
      request(:reset)
      output(:reject_gate_active?, :boolean, default: false, public?: true)
      signal(:reject_latched)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:reject_gate_active?, false)
      end

      state :latched do
        set_output(:reject_gate_active?, true)
        signal(:reject_latched)
      end
    end

    transitions do
      transition :idle, :latched do
        on({:request, :reject})
        reply(:ok)
      end

      transition :latched, :latched do
        on({:request, :reject})
        reenter?(true)
        reply(:ok)
      end

      transition :latched, :idle do
        on({:request, :reset})
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :reset})
        reply(:ok)
      end
    end
  end

  defmodule CellController do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:pack_and_inspect_cell)
      meaning("Coordinates infeed, clamp, inspection, and reject handling over one EtherCAT ring")
    end

    uses do
      dependency(:infeed_conveyor, skills: [:feed_part, :reset], signals: [:part_arrived])
      dependency(:clamp_station, skills: [:close, :open], signals: [:clamp_closed])

      dependency(:inspection_station,
        skills: [:inspect, :reset],
        signals: [:inspection_passed, :inspection_failed]
      )

      dependency(:reject_gate, skills: [:reject, :reset], signals: [:reject_latched])
    end

    boundary do
      request(:start_cycle)
      request(:reset_cell)
      event(:part_arrived)
      event(:clamp_ready)
      event(:inspection_passed)
      event(:inspection_failed)
      event(:dependency_down)
      output(:busy?, :boolean, default: false, public?: true)
      output(:pass_ready?, :boolean, default: false, public?: true)
      output(:reject_active?, :boolean, default: false, public?: true)
      signal(:cycle_started)
      signal(:part_staged)
      signal(:clamp_verified)
      signal(:cycle_passed)
      signal(:cycle_rejected)
      signal(:cell_reset)
      signal(:dependency_fault)
    end

    memory do
      field(:completed_cycles, :integer, default: 0)
      field(:rejected_cycles, :integer, default: 0)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:busy?, false)
        set_output(:pass_ready?, false)
        set_output(:reject_active?, false)
      end

      state :feeding do
        set_output(:busy?, true)
        set_output(:pass_ready?, false)
        set_output(:reject_active?, false)
      end

      state :clamping do
        set_output(:busy?, true)
        set_output(:pass_ready?, false)
        set_output(:reject_active?, false)
      end

      state :inspecting do
        set_output(:busy?, true)
        set_output(:pass_ready?, false)
        set_output(:reject_active?, false)
      end

      state :passed do
        set_output(:busy?, false)
        set_output(:pass_ready?, true)
        set_output(:reject_active?, false)
      end

      state :rejected do
        set_output(:busy?, false)
        set_output(:pass_ready?, false)
        set_output(:reject_active?, true)
      end

      state :fault do
        set_output(:busy?, false)
        set_output(:pass_ready?, false)
        set_output(:reject_active?, true)
      end
    end

    transitions do
      transition :idle, :feeding do
        on({:request, :start_cycle})
        signal(:cycle_started)
        invoke(:infeed_conveyor, :feed_part)
        reply(:ok)
      end

      transition :feeding, :clamping do
        on({:event, :part_arrived})
        guard(Ogol.Machine.Helpers.callback(:from_infeed?))
        signal(:part_staged)
        invoke(:clamp_station, :close)
      end

      transition :clamping, :inspecting do
        on({:event, :clamp_ready})
        guard(Ogol.Machine.Helpers.callback(:from_clamp?))
        signal(:clamp_verified)
        invoke(:inspection_station, :inspect)
      end

      transition :inspecting, :passed do
        on({:event, :inspection_passed})
        guard(Ogol.Machine.Helpers.callback(:from_inspector?))
        callback(:increment_completed_cycles)
        signal(:cycle_passed)
      end

      transition :inspecting, :rejected do
        on({:event, :inspection_failed})
        guard(Ogol.Machine.Helpers.callback(:from_inspector?))
        callback(:increment_rejected_cycles)
        invoke(:reject_gate, :reject)
        signal(:cycle_rejected)
      end

      transition :passed, :idle do
        on({:request, :reset_cell})
        invoke(:infeed_conveyor, :reset)
        invoke(:clamp_station, :open)
        invoke(:inspection_station, :reset)
        invoke(:reject_gate, :reset)
        signal(:cell_reset)
        reply(:ok)
      end

      transition :rejected, :idle do
        on({:request, :reset_cell})
        invoke(:infeed_conveyor, :reset)
        invoke(:clamp_station, :open)
        invoke(:inspection_station, :reset)
        invoke(:reject_gate, :reset)
        signal(:cell_reset)
        reply(:ok)
      end

      transition :fault, :idle do
        on({:request, :reset_cell})
        invoke(:infeed_conveyor, :reset)
        invoke(:clamp_station, :open)
        invoke(:inspection_station, :reset)
        invoke(:reject_gate, :reset)
        signal(:cell_reset)
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :reset_cell})
        invoke(:infeed_conveyor, :reset)
        invoke(:clamp_station, :open)
        invoke(:inspection_station, :reset)
        invoke(:reject_gate, :reset)
        signal(:cell_reset)
        reply(:ok)
      end

      transition :feeding, :fault do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end

      transition :clamping, :fault do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end

      transition :inspecting, :fault do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end

      transition :passed, :fault do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end

      transition :rejected, :fault do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end
    end

    safety do
      always(Ogol.Machine.Helpers.callback(:counters_valid?))
    end

    def from_infeed?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      dependency_event?(meta, :infeed_conveyor)
    end

    def from_clamp?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      dependency_event?(meta, :clamp_station)
    end

    def from_inspector?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      dependency_event?(meta, :inspection_station)
    end

    def from_known_dependency?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      dependency_event?(meta, :infeed_conveyor) or
        dependency_event?(meta, :clamp_station) or
        dependency_event?(meta, :inspection_station) or
        dependency_event?(meta, :reject_gate)
    end

    def increment_completed_cycles(_delivered, data, staging) do
      current = Map.get(data.fields, :completed_cycles, 0)

      next_data = %{
        staging.data
        | fields: Map.put(staging.data.fields, :completed_cycles, current + 1)
      }

      {:ok, %{staging | data: next_data}}
    end

    def increment_rejected_cycles(_delivered, data, staging) do
      current = Map.get(data.fields, :rejected_cycles, 0)

      next_data = %{
        staging.data
        | fields: Map.put(staging.data.fields, :rejected_cycles, current + 1)
      }

      {:ok, %{staging | data: next_data}}
    end

    def counters_valid?(data) do
      completed = Map.get(data.fields, :completed_cycles, 0)
      rejected = Map.get(data.fields, :rejected_cycles, 0)
      is_integer(completed) and completed >= 0 and is_integer(rejected) and rejected >= 0
    end

    defp dependency_event?(meta, dependency_name) do
      meta[:origin] == :dependency and meta[:dependency] == dependency_name and
        is_pid(meta[:dependency_pid])
    end
  end

  @spec boot!(keyword()) :: demo()
  def boot!(opts \\ []) do
    ensure_not_running!()

    signal_sink = Keyword.get(opts, :signal_sink, self())

    _ = EtherCAT.stop()
    _ = Simulator.stop()

    {:ok, simulator} =
      Simulator.start(
        devices: [
          SimulatorSlave.from_driver(EK1100, name: :coupler),
          SimulatorSlave.from_driver(EL1809, name: :inputs),
          SimulatorSlave.from_driver(EL2809, name: :outputs)
        ],
        backend: {:udp, %{host: @simulator_ip, port: 0}}
      )

    {:ok, %SimulatorStatus{backend: %Backend.Udp{port: port}}} = Simulator.status()

    :ok =
      EtherCAT.start(
        backend: {:udp, %{host: @simulator_ip, bind_ip: @master_ip, port: port}},
        dc: nil,
        domains: [[id: :main, cycle_time_us: 1_000]],
        slaves: master_slave_specs(),
        scan_stable_ms: @scan_stable_ms,
        scan_poll_ms: @scan_poll_ms,
        frame_timeout_ms: @frame_timeout_ms
      )

    :ok = EtherCAT.await_running(2_000)
    %Master.Status{lifecycle: :operational} = Master.status()

    {:ok, topology} =
      CellTopology.start_link(
        signal_sink: signal_sink,
        machine_opts: machine_opts()
      )

    clear_inputs()

    %{
      topology: topology,
      brain: CellTopology.brain_pid(topology),
      infeed: CellTopology.machine_pid(topology, :infeed_conveyor),
      clamp: CellTopology.machine_pid(topology, :clamp_station),
      inspector: CellTopology.machine_pid(topology, :inspection_station),
      reject_gate: CellTopology.machine_pid(topology, :reject_gate),
      simulator_port: port,
      simulator: simulator
    }
  end

  @spec invoke(demo() | pid(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(target, name, args \\ %{}, opts \\ [])

  def invoke(%{topology: topology}, name, args, opts), do: invoke(topology, name, args, opts)

  def invoke(topology, name, args, opts) when is_pid(topology),
    do: Ogol.invoke(topology, name, args, opts)

  @spec machine_pid(demo() | pid(), atom()) :: pid() | nil
  def machine_pid(%{topology: topology}, machine_name), do: machine_pid(topology, machine_name)

  def machine_pid(topology, machine_name) when is_pid(topology),
    do: CellTopology.machine_pid(topology, machine_name)

  @spec machine_state(demo() | pid(), atom()) :: atom() | nil
  def machine_state(target, machine_name) do
    case machine_pid(target, machine_name) do
      pid when is_pid(pid) ->
        case :sys.get_state(pid) do
          {state_name, _data} when is_atom(state_name) -> state_name
          _other -> nil
        end

      _other ->
        nil
    end
  end

  @spec set_input(atom(), boolean()) :: :ok | {:error, term()}
  def set_input(name, value) when is_atom(name) and is_boolean(value) do
    Simulator.set_value(:inputs, input_signal(name), value)
  end

  @spec clear_inputs() :: :ok
  def clear_inputs do
    Enum.each([:part_at_stop, :clamp_closed, :inspection_ok, :inspection_reject], fn input ->
      :ok = set_input(input, false)
    end)

    :ok
  end

  @spec output_snapshot() :: map()
  def output_snapshot do
    %{
      conveyor_run: read_output!(:ch1),
      clamp_extend: read_output!(:ch2),
      inspection_active: read_output!(:ch3),
      reject_gate: read_output!(:ch4),
      busy_lamp: read_output!(:ch5),
      good_lamp: read_output!(:ch6),
      reject_lamp: read_output!(:ch7)
    }
  end

  @spec input_snapshot() :: map()
  def input_snapshot do
    %{
      part_at_stop: read_input!(:ch1),
      clamp_closed: read_input!(:ch2),
      inspection_ok: read_input!(:ch3),
      inspection_reject: read_input!(:ch4)
    }
  end

  @spec snapshot(demo()) :: map()
  def snapshot(demo) do
    %{
      inputs: input_snapshot(),
      outputs: output_snapshot(),
      master: Master.status(),
      root_status: Ogol.status(demo.topology),
      machine_states: %{
        pack_and_inspect_cell: machine_state(demo, :pack_and_inspect_cell),
        infeed_conveyor: machine_state(demo, :infeed_conveyor),
        clamp_station: machine_state(demo, :clamp_station),
        inspection_station: machine_state(demo, :inspection_station),
        reject_gate: machine_state(demo, :reject_gate)
      }
    }
  end

  @spec run_passing_cycle!(demo()) :: :ok
  def run_passing_cycle!(demo) do
    {:ok, :ok} = invoke(demo, :start_cycle)
    assert_eventually(fn -> output_snapshot().conveyor_run end)

    :ok = set_input(:part_at_stop, true)
    assert_eventually(fn -> machine_state(demo, :infeed_conveyor) == :positioned end)

    :ok = set_input(:clamp_closed, true)
    assert_eventually(fn -> machine_state(demo, :inspection_station) == :inspecting end)

    :ok = set_input(:inspection_ok, true)
    assert_eventually(fn -> machine_state(demo, :pack_and_inspect_cell) == :passed end)
    :ok
  end

  @spec run_reject_cycle!(demo()) :: :ok
  def run_reject_cycle!(demo) do
    {:ok, :ok} = invoke(demo, :start_cycle)
    assert_eventually(fn -> output_snapshot().conveyor_run end)

    :ok = set_input(:part_at_stop, true)
    assert_eventually(fn -> machine_state(demo, :infeed_conveyor) == :positioned end)

    :ok = set_input(:clamp_closed, true)
    assert_eventually(fn -> machine_state(demo, :inspection_station) == :inspecting end)

    :ok = set_input(:inspection_reject, true)
    assert_eventually(fn -> machine_state(demo, :pack_and_inspect_cell) == :rejected end)
    :ok
  end

  @spec stop(demo() | pid() | nil) :: :ok
  def stop(target \\ nil)

  def stop(%{topology: topology}), do: stop(topology)

  def stop(topology) when is_pid(topology) do
    if Process.alive?(topology) do
      GenServer.stop(topology, :shutdown)
    end

    await_registry_clear(@machines)
    stop_runtime()
  catch
    :exit, _reason ->
      stop_runtime()
  end

  def stop(nil), do: stop_runtime()

  defp stop_runtime do
    _ = EtherCAT.stop()
    _ = Simulator.stop()
    :ok
  end

  defp ensure_not_running! do
    if Enum.any?(@machines, &(Registry.whereis(&1) != nil)) do
      raise "PackAndInspectCellDemo is already running. Stop the existing demo before booting another one."
    end
  end

  defp machine_opts do
    %{
      pack_and_inspect_cell: [
        hardware_ref: [
          %Ref{
            slave: :outputs,
            outputs: [:busy?, :pass_ready?, :reject_active?]
          }
        ]
      ],
      infeed_conveyor: [
        hardware_ref: [
          %Ref{slave: :outputs, outputs: [:conveyor_run?]},
          %Ref{slave: :inputs, facts: [:part_at_stop?]}
        ]
      ],
      clamp_station: [
        hardware_ref: [
          %Ref{slave: :outputs, outputs: [:clamp_extend?]},
          %Ref{slave: :inputs, facts: [:clamp_closed?]}
        ]
      ],
      inspection_station: [
        hardware_ref: [
          %Ref{slave: :outputs, outputs: [:inspection_active?]},
          %Ref{slave: :inputs, facts: [:inspection_ok?, :inspection_reject?]}
        ]
      ],
      reject_gate: [
        hardware_ref: [
          %Ref{slave: :outputs, outputs: [:reject_gate_active?]}
        ]
      ]
    }
  end

  defp master_slave_specs do
    [
      %SlaveConfig{
        name: :coupler,
        driver: EK1100,
        process_data: :none,
        target_state: :op,
        health_poll_ms: nil
      },
      %SlaveConfig{
        name: :inputs,
        driver: EL1809,
        aliases: %{
          ch1: :part_at_stop?,
          ch2: :clamp_closed?,
          ch3: :inspection_ok?,
          ch4: :inspection_reject?
        },
        process_data: {:all, :main},
        target_state: :op,
        health_poll_ms: nil
      },
      %SlaveConfig{
        name: :outputs,
        driver: EL2809,
        aliases: %{
          ch1: :conveyor_run?,
          ch2: :clamp_extend?,
          ch3: :inspection_active?,
          ch4: :reject_gate_active?,
          ch5: :busy?,
          ch6: :pass_ready?,
          ch7: :reject_active?
        },
        process_data: {:all, :main},
        target_state: :op,
        health_poll_ms: nil
      }
    ]
  end

  defp input_signal(:part_at_stop), do: :ch1
  defp input_signal(:clamp_closed), do: :ch2
  defp input_signal(:inspection_ok), do: :ch3
  defp input_signal(:inspection_reject), do: :ch4

  defp read_input!(signal) do
    {:ok, value} = Simulator.get_value(:inputs, signal)
    value
  end

  defp read_output!(signal) do
    {:ok, value} = Simulator.get_value(:outputs, signal)
    value
  end

  defp assert_eventually(fun, attempts \\ @await_attempts)

  defp assert_eventually(fun, 0) do
    case fun.() do
      true -> :ok
      false -> raise "expected condition to become true"
    end
  end

  defp assert_eventually(fun, attempts) do
    case fun.() do
      true ->
        :ok

      false ->
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
    end
  end

  defp await_registry_clear(names, attempts \\ @await_attempts)

  defp await_registry_clear(_names, 0), do: :ok

  defp await_registry_clear(names, attempts) do
    if Enum.all?(names, &(Registry.whereis(&1) == nil)) do
      :ok
    else
      Process.sleep(25)
      await_registry_clear(names, attempts - 1)
    end
  end
end
