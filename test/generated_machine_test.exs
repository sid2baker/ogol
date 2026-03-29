defmodule GeneratedMachineTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Backend
  alias EtherCAT.Driver.{EL1809, EL2809}
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias EtherCAT.Simulator.Slave, as: SimulatorSlave
  alias EtherCAT.Slave.Config, as: SlaveConfig

  alias Ogol.TestSupport.{
    CallbackActionMachine,
    DuplicateReplyMachine,
    EthercatFeedbackMachine,
    EthercatFilteredFeedbackMachine,
    EntrySignalLeakMachine,
    FactPatchMachine,
    ForeignActionMachine,
    HibernateMachine,
    MissingReplyMachine,
    SampleMachine,
    SafetyDropMachine,
    StopMachine,
    TestHardwareAdapter,
    TimeoutMachine
  }

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  setup do
    _ = EtherCAT.stop()
    _ = Simulator.stop()

    on_exit(fn ->
      _ = EtherCAT.stop()
      _ = Simulator.stop()
    end)

    :ok
  end

  test "sample machine starts and handles request into next state" do
    {:ok, pid} =
      SampleMachine.start_link(
        signal_sink: self(),
        hardware_adapter: TestHardwareAdapter,
        hardware_ref: self()
      )

    assert_receive {:hardware_output, :running?, false, %{}}
    assert {:ok, :ok} = Ogol.invoke(pid, :start)
    assert_receive {:ogol_signal, :sample_machine, :started, %{}, %{}}
    assert_receive {:hardware_command, :start_motor, %{}, %{}}
    assert_receive {:hardware_output, :running?, true, %{}}
    assert {:running, data} = :sys.get_state(pid)
    assert data.outputs[:running?] == true
  end

  test "matched request without reply stops with missing reply" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = MissingReplyMachine.start_link()

    assert catch_exit(Ogol.Runtime.Delivery.request(pid, :start, %{}, %{}, 100))
    assert_receive {:EXIT, ^pid, {:missing_reply}}
  end

  test "duplicate reply stops with invalid reply cardinality" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = DuplicateReplyMachine.start_link()

    assert catch_exit(Ogol.Runtime.Delivery.request(pid, :start, %{}, %{}, 100))
    assert_receive {:EXIT, ^pid, {:invalid_reply_cardinality, 2}}
  end

  test "state entry effects do not leak when the enclosing request fails validation" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = EntrySignalLeakMachine.start_link(signal_sink: self())

    assert catch_exit(Ogol.Runtime.Delivery.request(pid, :start, %{}, %{}, 100))
    refute_receive {:ogol_signal, :entry_signal_leak_machine, :entered, %{}, %{}}, 50
    assert_receive {:EXIT, ^pid, {:missing_reply}}
  end

  test "eligible fact patch merges before guard evaluation" do
    {:ok, pid} = FactPatchMachine.start_link(signal_sink: self())

    :ok = Ogol.Runtime.Delivery.event(pid, :sensor_changed, %{facts: %{ready?: true}})
    assert_receive {:ogol_signal, :fact_patch_machine, :started, %{}, %{}}
    assert {:running, _data} = :sys.get_state(pid)
  end

  test "staged signal and command are dropped if safety fails" do
    Process.flag(:trap_exit, true)

    {:ok, pid} =
      SafetyDropMachine.start_link(
        signal_sink: self(),
        hardware_adapter: TestHardwareAdapter,
        hardware_ref: self()
      )

    assert catch_exit(Ogol.Runtime.Delivery.request(pid, :start, %{}, %{}, 100))
    refute_receive {:ogol_signal, _, _, _, _}, 50
    refute_receive {:hardware_command, _, _, _}, 50
    assert_receive {:EXIT, ^pid, {:safety_violation, {:callback, :always_fail}, :running}}
  end

  test "named timeout replacement keeps only the latest timeout" do
    {:ok, pid} = TimeoutMachine.start_link(signal_sink: self())

    assert {:ok, :ok} = Ogol.invoke(pid, :start)
    {:idle, data} = :sys.get_state(pid)
    assert %{watchdog: _ref} = data.meta.timeout_refs
  end

  test "command dispatch is not treated as proof of effect" do
    {:ok, pid} =
      SampleMachine.start_link(
        signal_sink: self(),
        hardware_adapter: TestHardwareAdapter,
        hardware_ref: self()
      )

    assert_receive {:hardware_output, :running?, false, %{}}
    assert {:ok, :ok} = Ogol.invoke(pid, :start)
    assert_receive {:hardware_output, :running?, true, %{}}
    assert {:running, data} = :sys.get_state(pid)
    refute Map.has_key?(data.facts, :motor_started?)
  end

  test "ethercat adapter emits explicit ethercat command and output messages" do
    boot_ethercat_master!(
      [
        SimulatorSlave.from_driver(EL2809, name: :outputs)
      ],
      [
        %SlaveConfig{
          name: :outputs,
          driver: EL2809,
          aliases: %{ch1: :running?, ch2: :start_motor},
          process_data: {:all, :main},
          target_state: :op,
          health_poll_ms: nil
        }
      ]
    )

    {:ok, pid} =
      SampleMachine.start_link(
        signal_sink: self(),
        hardware_ref: %Ogol.Hardware.EtherCAT.Ref{
          slave: :outputs,
          outputs: [:running?],
          commands: %{
            start_motor: {:command, :set_output, %{endpoint: :start_motor, value: true}}
          }
        }
      )

    assert {:ok, false} = Simulator.get_value(:outputs, :ch1)
    assert {:ok, false} = Simulator.get_value(:outputs, :ch2)

    assert {:ok, :ok} = Ogol.invoke(pid, :start)

    assert_receive {:ogol_signal, :sample_machine, :started, %{}, %{}}, 500
    assert_eventually(fn -> Simulator.get_value(:outputs, :ch1) == {:ok, true} end)
    assert_eventually(fn -> Simulator.get_value(:outputs, :ch2) == {:ok, true} end)
  end

  test "ethercat process image feedback enters only as a hardware event" do
    boot_ethercat_master!(
      [
        SimulatorSlave.from_driver(EL1809, name: :inputs)
      ],
      [
        %SlaveConfig{
          name: :inputs,
          driver: EL1809,
          aliases: %{ch1: :ready?},
          process_data: {:all, :main},
          target_state: :op,
          health_poll_ms: nil
        }
      ]
    )

    {:ok, pid} =
      EthercatFeedbackMachine.start_link(
        signal_sink: self(),
        hardware_ref: %Ogol.Hardware.EtherCAT.Ref{
          slave: :inputs,
          facts: [:ready?]
        }
      )

    assert_eventually(fn ->
      :ok = Simulator.set_value(:inputs, :ch1, true)
      match?({:running, _data}, :sys.get_state(pid))
    end)

    assert {:running, data} = :sys.get_state(pid)
    assert data.facts[:ready?] == true
  end

  test "ethercat adapter ignores unrelated subscribed signal changes" do
    boot_ethercat_master!(
      [
        SimulatorSlave.from_driver(EthercatFilteredFeedbackMachine.Driver, name: :io)
      ],
      [
        %SlaveConfig{
          name: :io,
          driver: EthercatFilteredFeedbackMachine.Driver,
          aliases: %{lamp: :lamp?, sensor1: :sensor1?, sensor2: :sensor2?},
          process_data: {:all, :main},
          target_state: :op,
          health_poll_ms: nil
        }
      ]
    )

    {:ok, pid} =
      EthercatFilteredFeedbackMachine.start_link(
        signal_sink: self(),
        hardware_ref: %Ogol.Hardware.EtherCAT.Ref{
          slave: :io,
          outputs: [:lamp?],
          facts: [:sensor1?, :sensor2?]
        }
      )

    assert {:ok, :ok} = Ogol.invoke(pid, :start)
    refute_receive {:ogol_signal, :ethercat_filtered_feedback_machine, :advanced, %{}, %{}}, 50

    assert {:waiting, data} = :sys.get_state(pid)
    assert data.outputs[:lamp?] == true
    assert data.facts[:sensor1?] == false
    assert data.facts[:sensor2?] == false
  end

  test "stop without reply on a request exits without inventing missing reply" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = StopMachine.start_link()

    assert catch_exit(Ogol.Runtime.Delivery.request(pid, :stop_now, %{}, %{}, 100))
    assert_receive {:EXIT, ^pid, :shutdown}
  end

  test "stop with reply returns the reply before exiting" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = StopMachine.start_link()

    assert :ok = Ogol.Runtime.Delivery.request(pid, :stop_and_reply, %{}, %{}, 100)
    assert_receive {:EXIT, ^pid, :shutdown}
  end

  test "hibernate action keeps the machine runnable" do
    {:ok, pid} = HibernateMachine.start_link()

    assert :ok = Ogol.Runtime.Delivery.request(pid, :sleep)
    assert :pong = Ogol.Runtime.Delivery.request(pid, :ping)
    assert {:idle, _data} = :sys.get_state(pid)
  end

  test "callback action can mutate staging and stage explicit effects" do
    {:ok, pid} = CallbackActionMachine.start_link(signal_sink: self())

    assert {:ok, :ok} = Ogol.invoke(pid, :start)
    assert_receive {:ogol_signal, :callback_action_machine, :callback_ran, %{}, %{via: :callback}}
    assert {:idle, data} = :sys.get_state(pid)
    assert data.fields[:count] == 1
  end

  test "foreign action delegates to an explicit foreign module" do
    {:ok, pid} = ForeignActionMachine.start_link(signal_sink: self())

    assert {:ok, :ok} = Ogol.invoke(pid, :start)
    assert_receive {:ogol_signal, :foreign_action_machine, :foreign_ran, %{}, %{via: :foreign}}
    assert {:idle, data} = :sys.get_state(pid)
    assert data.fields[:status] == :foreign
  end

  defp boot_ethercat_master!(devices, slaves) do
    start_supervised!(
      {Simulator, devices: devices, backend: {:udp, %{host: @simulator_ip, port: 0}}}
    )

    assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: port}}} = Simulator.status()

    :ok =
      EtherCAT.start(
        backend: {:udp, %{host: @simulator_ip, bind_ip: @master_ip, port: port}},
        dc: nil,
        domains: [[id: :main, cycle_time_us: 1_000]],
        slaves: slaves,
        scan_stable_ms: 20,
        scan_poll_ms: 10,
        frame_timeout_ms: 20
      )

    :ok = EtherCAT.await_operational(2_000)
    assert %Master.Status{lifecycle: :operational} = Master.status()
    :ok
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    case fun.() do
      true ->
        :ok

      false ->
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
    end
  end
end
