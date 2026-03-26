defmodule Ogol.Examples.EthercatSimulatorDemo do
  @moduledoc """
  Runnable EtherCAT simulator example using the stock `EL1809` and `EL2809`
  drivers from the external `:ethercat` dependency.

  This example keeps the layering simple:

  - Ogol owns the machine brain
  - `EtherCAT.Simulator` owns the simulated fieldbus/runtime
  - the Ogol EtherCAT adapter maps one machine onto separate input and output
    slaves through multiple hardware refs

  In IEx:

      iex -S mix
      demo = Ogol.Examples.EthercatSimulatorDemo.boot!()
      Ogol.request(demo.machine, :start_cycle)
      Ogol.Examples.EthercatSimulatorDemo.snapshot()
      Ogol.Examples.EthercatSimulatorDemo.set_closed(true)
      flush()
      :sys.get_state(demo.machine)
      Ogol.Examples.EthercatSimulatorDemo.stop()
  """

  alias EtherCAT.Driver.{EL1809, EL2809}
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave, as: SimulatorSlave
  alias Ogol.Hardware.EtherCAT.Ref

  defmodule ClampMachine do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:ethercat_simulator_clamp)
      meaning("Minimal machine backed by stock EL1809 and EL2809 simulator devices")
    end

    boundary do
      fact(:clamp_closed?, :boolean, default: false)
      request(:start_cycle)
      command(:close_clamp)
      output(:run_lamp?, :boolean, default: false)
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

  @spec boot!(keyword()) :: %{machine: pid(), simulator: pid()}
  def boot!(opts \\ []) do
    signal_sink = Keyword.get(opts, :signal_sink, self())
    _ = Simulator.stop()

    {:ok, simulator} =
      Simulator.start_link(
        devices: [
          SimulatorSlave.from_driver(EL1809, name: :inputs),
          SimulatorSlave.from_driver(EL2809, name: :outputs)
        ]
      )

    {:ok, machine} =
      ClampMachine.start_link(
        signal_sink: signal_sink,
        hardware_adapter: Ogol.Hardware.EtherCAT.Adapter,
        hardware_ref: [
          %Ref{
            mode: :simulator,
            slave: :outputs,
            command_map: %{
              close_clamp: {:command, :set_output, %{signal: :ch2, value: true}}
            },
            output_map: %{run_lamp?: :ch1}
          },
          %Ref{
            mode: :simulator,
            slave: :inputs,
            fact_map: %{ch1: :clamp_closed?}
          }
        ]
      )

    %{machine: machine, simulator: simulator}
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
    Simulator.stop()
  end
end
