defmodule Ogol.TestSupport.EthercatHmiFixture do
  @moduledoc false

  import ExUnit.Assertions

  alias EtherCAT.Backend
  alias EtherCAT.Driver.{EK1100, EL1809, EL2809}
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias EtherCAT.Simulator.Slave, as: SimSlave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  @spec boot_simulator_only!() :: %{simulator: pid(), port: :inet.port_number()}
  def boot_simulator_only! do
    _ = EtherCAT.stop()
    _ = Simulator.stop()

    {:ok, simulator} =
      Simulator.start(
        devices: [
          SimSlave.from_driver(EK1100, name: :coupler),
          SimSlave.from_driver(EL1809, name: :inputs),
          SimSlave.from_driver(EL2809, name: :outputs)
        ],
        backend: {:udp, %{host: @simulator_ip, port: 0}}
      )

    assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: port}}} = Simulator.status()

    %{simulator: simulator, port: port}
  end

  @spec boot_preop_ring!() :: %{simulator: pid(), port: :inet.port_number()}
  def boot_preop_ring! do
    %{simulator: simulator, port: port} = boot_simulator_only!()

    :ok =
      EtherCAT.start(
        backend: {:udp, %{host: @simulator_ip, bind_ip: @master_ip, port: port}},
        dc: nil,
        domains: [[id: :main, cycle_time_us: 1_000]],
        slaves: [
          %SlaveConfig{
            name: :coupler,
            driver: EK1100,
            process_data: :none,
            target_state: :preop,
            health_poll_ms: nil
          },
          %SlaveConfig{
            name: :inputs,
            driver: EL1809,
            process_data: :none,
            target_state: :preop,
            health_poll_ms: nil
          },
          %SlaveConfig{
            name: :outputs,
            driver: EL2809,
            process_data: :none,
            target_state: :preop,
            health_poll_ms: nil
          }
        ],
        scan_stable_ms: 20,
        scan_poll_ms: 10,
        frame_timeout_ms: 20
      )

    assert_eventually(fn -> match?(%Master.Status{lifecycle: :preop_ready}, Master.status()) end)

    %{simulator: simulator, port: port}
  end

  @spec stop_all!() :: :ok
  def stop_all! do
    case EtherCAT.stop() do
      :ok -> :ok
      {:error, :already_stopped} -> :ok
    end

    _ = Simulator.stop()
    :ok
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end
end
