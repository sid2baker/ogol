defmodule GeneratedMachineTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Driver.{EL1809, EL2809}
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Slave, as: SimulatorSlave

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

  setup do
    _ = Simulator.stop()

    on_exit(fn ->
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
    start_supervised!(
      {Simulator,
       devices: [
         SimulatorSlave.from_driver(EL2809, name: :outputs)
       ]}
    )

    {:ok, pid} =
      SampleMachine.start_link(
        signal_sink: self(),
        hardware_adapter: Ogol.Hardware.EtherCAT.Adapter,
        hardware_ref: %Ogol.Hardware.EtherCAT.Ref{
          mode: :simulator,
          slave: :outputs,
          command_map: %{start_motor: {:write_output, :ch2, true}},
          output_map: %{running?: :ch1}
        }
      )

    assert {:ok, false} = Simulator.get_value(:outputs, :ch1)
    assert {:ok, false} = Simulator.get_value(:outputs, :ch2)

    assert {:ok, :ok} = Ogol.invoke(pid, :start)

    assert_receive {:ogol_signal, :sample_machine, :started, %{}, %{}}
    assert {:ok, true} = Simulator.get_value(:outputs, :ch1)
    assert {:ok, true} = Simulator.get_value(:outputs, :ch2)
  end

  test "ethercat process image feedback enters only as a hardware event" do
    start_supervised!(
      {Simulator,
       devices: [
         SimulatorSlave.from_driver(EL1809, name: :inputs)
       ]}
    )

    {:ok, pid} =
      EthercatFeedbackMachine.start_link(
        signal_sink: self(),
        hardware_adapter: Ogol.Hardware.EtherCAT.Adapter,
        hardware_ref: %Ogol.Hardware.EtherCAT.Ref{
          mode: :simulator,
          slave: :inputs,
          fact_map: %{ch1: :ready?}
        }
      )

    assert :ok = Simulator.set_value(:inputs, :ch1, true)

    assert_receive {:ogol_signal, :ethercat_feedback_machine, :started, %{}, %{}}
    assert {:running, data} = :sys.get_state(pid)
    assert data.facts[:ready?] == true
  end

  test "ethercat adapter ignores unrelated subscribed signal changes" do
    start_supervised!(
      {Simulator,
       devices: [
         SimulatorSlave.from_driver(EthercatFilteredFeedbackMachine.Driver, name: :io)
       ]}
    )

    {:ok, pid} =
      EthercatFilteredFeedbackMachine.start_link(
        signal_sink: self(),
        hardware_adapter: Ogol.Hardware.EtherCAT.Adapter,
        hardware_ref: %Ogol.Hardware.EtherCAT.Ref{
          mode: :simulator,
          slave: :io,
          output_map: %{lamp?: :lamp},
          fact_map: %{sensor1: :sensor1?, sensor2: :sensor2?}
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
end
