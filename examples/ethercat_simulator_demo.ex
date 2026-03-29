defmodule Ogol.Examples.EthercatSimulatorDemo do
  @moduledoc """
  Runnable EtherCAT simulator-backed master example using the stock `EL1809`
  and `EL2809` drivers from the external `:ethercat` dependency.

  This example keeps the layering simple:

  - Ogol owns the machine brain
  - `EtherCAT.Simulator` provides fake hardware
  - `EtherCAT` owns the master/runtime
  - the Ogol EtherCAT adapter binds one machine onto aliased slave endpoints

  In IEx:

      iex -S mix
      demo = Ogol.Examples.EthercatSimulatorDemo.boot!()
      {:ok, :ok} = Ogol.invoke(demo.machine, :start_cycle)
      Ogol.status(demo.machine)
      Ogol.Examples.EthercatSimulatorDemo.set_closed(true)
      flush()
      Ogol.Examples.EthercatSimulatorDemo.snapshot()
      Ogol.Examples.EthercatSimulatorDemo.stop()
  """

  alias EtherCAT.Backend
  alias EtherCAT.Driver.{EL1809, EL2809}
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias EtherCAT.Simulator.Slave, as: SimulatorSlave
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware.EtherCAT.Ref

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  defmodule ClampMachine do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:ethercat_simulator_clamp)
      meaning("Minimal machine backed by stock EL1809 and EL2809 simulator devices")
    end

    boundary do
      fact(:clamp_closed?, :boolean, default: false, public?: true)
      request(:start_cycle)
      command(:close_clamp)
      output(:run_lamp?, :boolean, default: false, public?: true)
      signal(:waiting_for_clamp)
      signal(:cycle_started)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:run_lamp?, false)
      end

      state :arming do
        set_output(:run_lamp?, true)
      end

      state(:running)
    end

    transitions do
      transition :idle, :arming do
        on({:request, :start_cycle})
        command(:close_clamp)
        signal(:waiting_for_clamp)
        reply(:ok)
      end

      transition :arming, :running do
        on({:hardware, :process_image})
        guard(Ogol.Machine.Helpers.callback(:clamp_closed?))
        signal(:cycle_started)
      end
    end

    def clamp_closed?(%Ogol.Runtime.DeliveredEvent{meta: meta}, data) do
      meta[:bus] == :ethercat and Map.get(data.facts, :clamp_closed?, false)
    end
  end

  @spec boot!(keyword()) :: %{
          machine: pid(),
          simulator: pid(),
          simulator_port: :inet.port_number()
        }
  def boot!(opts \\ []) do
    signal_sink = Keyword.get(opts, :signal_sink, self())
    _ = EtherCAT.stop()
    _ = Simulator.stop()

    {:ok, simulator} =
      Simulator.start(
        devices: [
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
        slaves: [
          %SlaveConfig{
            name: :inputs,
            driver: EL1809,
            aliases: %{ch1: :clamp_closed?},
            process_data: {:all, :main},
            target_state: :op,
            health_poll_ms: nil
          },
          %SlaveConfig{
            name: :outputs,
            driver: EL2809,
            aliases: %{ch1: :run_lamp?, ch2: :close_clamp?},
            process_data: {:all, :main},
            target_state: :op,
            health_poll_ms: nil
          }
        ],
        scan_stable_ms: 20,
        scan_poll_ms: 10,
        frame_timeout_ms: 20
      )

    :ok = EtherCAT.await_operational(2_000)

    case Master.status() do
      %Master.Status{lifecycle: :operational} -> :ok
      other -> raise "expected operational master, got: #{inspect(other)}"
    end

    {:ok, machine} =
      ClampMachine.start_link(
        signal_sink: signal_sink,
        hardware_ref: [
          %Ref{
            slave: :outputs,
            outputs: [:run_lamp?],
            commands: %{
              close_clamp: {:command, :set_output, %{endpoint: :close_clamp?, value: true}}
            }
          },
          %Ref{
            slave: :inputs,
            facts: [:clamp_closed?]
          }
        ]
      )

    %{machine: machine, simulator: simulator, simulator_port: port}
  end

  @spec set_closed(boolean()) :: :ok | {:error, term()}
  def set_closed(value) when is_boolean(value) do
    Simulator.set_value(:inputs, :ch1, value)
  end

  @spec snapshot() :: %{
          run_lamp: boolean(),
          close_cmd: boolean(),
          closed_fb: boolean()
        }
  def snapshot do
    {:ok, run_lamp} = Simulator.get_value(:outputs, :ch1)
    {:ok, close_cmd} = Simulator.get_value(:outputs, :ch2)
    {:ok, closed_fb} = Simulator.get_value(:inputs, :ch1)

    %{run_lamp: run_lamp, close_cmd: close_cmd, closed_fb: closed_fb}
  end

  @spec stop() :: :ok | {:error, term()}
  def stop do
    _ = EtherCAT.stop()
    Simulator.stop()
  end
end
