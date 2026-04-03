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
    EthercatRuntimeHelper,
    EntrySignalLeakMachine,
    FactPatchMachine,
    ForeignActionMachine,
    HibernateMachine,
    MissingReplyMachine,
    PidControlMachine,
    SampleMachine,
    SafetyDropMachine,
    StopMachine,
    TestHardwareAdapter,
    TimeoutMachine
  }

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}

  setup do
    stop_active_topology()
    _ = EtherCAT.stop()
    _ = Simulator.stop()

    on_exit(fn ->
      stop_active_topology()
      _ = EtherCAT.stop()
      _ = Simulator.stop()
    end)

    :ok
  end

  test "sample machine starts and handles request into next state" do
    {:ok, pid} =
      SampleMachine.start_link(
        signal_sink: self(),
        io_adapter: TestHardwareAdapter,
        io_binding: self()
      )

    assert_receive {:hardware_output, :running?, false, %{}}
    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)
    assert_receive {:ogol_signal, :sample_machine, :started, %{}, %{}}
    assert_receive {:hardware_command, :start_motor, %{}, %{}}
    assert_receive {:hardware_output, :running?, true, %{}}
    assert {:running, data} = :sys.get_state(pid)
    assert data.outputs[:running?] == true
  end

  test "duplicate machine instance names fail startup instead of booting unregistered" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = SampleMachine.start_link(machine_id: :shared_sample_machine)

    on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    assert {:error, {:machine_already_running, :shared_sample_machine, ^pid}} =
             SampleMachine.start_link(machine_id: :shared_sample_machine)
  end

  test "machine modules can run multiple live instances with distinct ids" do
    Process.flag(:trap_exit, true)
    {:ok, primary_pid} = SampleMachine.start_link(machine_id: :primary_sample_machine)
    {:ok, backup_pid} = SampleMachine.start_link(machine_id: :backup_sample_machine)

    on_exit(fn ->
      for pid <- [primary_pid, backup_pid] do
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :shutdown)
          catch
            :exit, _reason -> :ok
          end
        end
      end
    end)

    assert primary_pid != backup_pid

    assert %Ogol.Machine.Status{machine_id: :primary_sample_machine} =
             SampleMachine.status(:primary_sample_machine)

    assert %Ogol.Machine.Status{machine_id: :backup_sample_machine} =
             SampleMachine.status(:backup_sample_machine)
  end

  test "matched request without reply stops with missing reply" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = MissingReplyMachine.start_link()

    assert catch_exit(Ogol.Runtime.request(pid, :start, %{}, %{}, 100))
    assert_receive {:EXIT, ^pid, {:missing_reply}}
  end

  test "duplicate reply stops with invalid reply cardinality" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = DuplicateReplyMachine.start_link()

    assert catch_exit(Ogol.Runtime.request(pid, :start, %{}, %{}, 100))
    assert_receive {:EXIT, ^pid, {:invalid_reply_cardinality, 2}}
  end

  test "state entry effects do not leak when the enclosing request fails validation" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = EntrySignalLeakMachine.start_link(signal_sink: self())

    assert catch_exit(Ogol.Runtime.request(pid, :start, %{}, %{}, 100))
    refute_receive {:ogol_signal, :entry_signal_leak_machine, :entered, %{}, %{}}, 50
    assert_receive {:EXIT, ^pid, {:missing_reply}}
  end

  test "eligible fact patch merges before guard evaluation" do
    {:ok, pid} = FactPatchMachine.start_link(signal_sink: self())

    :ok = Ogol.Runtime.event(pid, :sensor_changed, %{facts: %{ready?: true}})
    assert_receive {:ogol_signal, :fact_patch_machine, :started, %{}, %{}}
    assert {:running, _data} = :sys.get_state(pid)
  end

  test "staged signal and command are dropped if safety fails" do
    Process.flag(:trap_exit, true)

    {:ok, pid} =
      SafetyDropMachine.start_link(
        signal_sink: self(),
        io_adapter: TestHardwareAdapter,
        io_binding: self()
      )

    assert catch_exit(Ogol.Runtime.request(pid, :start, %{}, %{}, 100))
    refute_receive {:ogol_signal, _, _, _, _}, 50
    refute_receive {:hardware_command, _, _, _}, 50
    assert_receive {:EXIT, ^pid, {:safety_violation, {:callback, :always_fail}, :running}}
  end

  test "named timeout replacement keeps only the latest timeout" do
    {:ok, pid} = TimeoutMachine.start_link(signal_sink: self())

    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)
    {:idle, data} = :sys.get_state(pid)
    assert %{watchdog: _ref} = data.meta.timeout_refs
  end

  test "command dispatch is not treated as proof of effect" do
    {:ok, pid} =
      SampleMachine.start_link(
        signal_sink: self(),
        io_adapter: TestHardwareAdapter,
        io_binding: self()
      )

    assert_receive {:hardware_output, :running?, false, %{}}
    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)
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
        io_binding: %{
          slave: :outputs,
          outputs: %{running?: :running?},
          commands: %{
            start_motor: {:command, :set_output, %{endpoint: :start_motor, value: true}}
          }
        }
      )

    assert {:ok, false} = Simulator.get_value(:outputs, :ch1)
    assert {:ok, false} = Simulator.get_value(:outputs, :ch2)

    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)

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
        io_binding: %{
          slave: :inputs,
          facts: %{ready?: :ready?}
        }
      )

    assert_eventually(fn ->
      :ok = Simulator.set_value(:inputs, :ch1, false)
      Process.sleep(10)
      :ok = Simulator.set_value(:inputs, :ch1, true)
      Process.sleep(10)
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
        io_binding: %{
          slave: :io,
          outputs: %{lamp?: :lamp?},
          facts: %{sensor1?: :sensor1?, sensor2?: :sensor2?}
        }
      )

    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)
    refute_receive {:ogol_signal, :ethercat_filtered_feedback_machine, :advanced, %{}, %{}}, 50

    assert {:waiting, data} = :sys.get_state(pid)
    assert data.outputs[:lamp?] == true
    assert data.facts[:sensor1?] == false
    assert data.facts[:sensor2?] == false
  end

  test "stop without reply on a request exits without inventing missing reply" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = StopMachine.start_link()

    assert catch_exit(Ogol.Runtime.request(pid, :stop_now, %{}, %{}, 100))
    assert_receive {:EXIT, ^pid, :shutdown}
  end

  test "stop with reply returns the reply before exiting" do
    Process.flag(:trap_exit, true)
    {:ok, pid} = StopMachine.start_link()

    assert :ok = Ogol.Runtime.request(pid, :stop_and_reply, %{}, %{}, 100)
    assert_receive {:EXIT, ^pid, :shutdown}
  end

  test "hibernate action keeps the machine runnable" do
    {:ok, pid} = HibernateMachine.start_link()

    assert :ok = Ogol.Runtime.request(pid, :sleep)
    assert :pong = Ogol.Runtime.request(pid, :ping)
    assert {:idle, _data} = :sys.get_state(pid)
  end

  test "callback action can mutate staging and stage explicit effects" do
    {:ok, pid} = CallbackActionMachine.start_link(signal_sink: self())

    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)
    assert_receive {:ogol_signal, :callback_action_machine, :callback_ran, %{}, %{via: :callback}}
    assert {:idle, data} = :sys.get_state(pid)
    assert data.fields[:count] == 1
  end

  test "foreign action delegates to an explicit foreign module" do
    {:ok, pid} = ForeignActionMachine.start_link(signal_sink: self())

    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)
    assert_receive {:ogol_signal, :foreign_action_machine, :foreign_ran, %{}, %{via: :foreign}}
    assert {:idle, data} = :sys.get_state(pid)
    assert data.fields[:status] == :foreign
  end

  test "pid foreign action drives local control output from facts and resets on stop" do
    {:ok, pid} = PidControlMachine.start_link(signal_sink: self())

    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)

    assert_receive {:ogol_signal, :pid_control_machine, :pid_tick, %{}, %{}}, 200

    assert_eventually(fn ->
      {:controlling, data} = :sys.get_state(pid)
      data.outputs[:control_output] == 20.0 and data.fields[:previous_error] == 10.0
    end)

    :ok = Ogol.Runtime.event(pid, :sample, %{facts: %{process_value: 4.0}})
    assert_receive {:ogol_signal, :pid_control_machine, :pid_tick, %{}, %{}}, 200

    assert_eventually(fn ->
      {:controlling, data} = :sys.get_state(pid)

      data.outputs[:control_output] == 12.0 and
        data.fields[:previous_error] == 6.0 and
        is_integer(data.fields[:previous_timestamp])
    end)

    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :stop)

    assert_eventually(fn ->
      {:idle, data} = :sys.get_state(pid)

      data.outputs[:control_output] == 0.0 and
        data.fields[:integral] == 0.0 and
        data.fields[:previous_timestamp] == nil
    end)
  end

  test "topology-authored wiring resolves machine ports against endpoint aliases" do
    boot_ethercat_simulator!([
      SimulatorSlave.from_driver(EL2809, name: :outputs)
    ])

    topology_module = unique_module("AuthoredEthercatWiringTopology")

    Code.compile_string("""
    defmodule #{inspect(topology_module)} do
      use Ogol.Topology

      topology do
        strategy(:one_for_one)
      end

      machines do
        machine(:bound_machine, Ogol.TestSupport.AuthoredEthercatBoundMachine,
          wiring: [
            outputs: [running?: :running?],
            commands: [
              start_motor:
                {:command, :set_output, [endpoint: :start_motor, value: true]}
            ]
          ]
        )
      end
    end
    """)

    hardware_config = %Ogol.Hardware.Config.EtherCAT{
      id: "test_hardware",
      label: "Test EtherCAT",
      transport: %Ogol.Hardware.Config.EtherCAT.Transport{
        mode: :udp,
        bind_ip: @master_ip,
        primary_interface: nil,
        secondary_interface: nil
      },
      timing: %Ogol.Hardware.Config.EtherCAT.Timing{
        scan_stable_ms: 20,
        scan_poll_ms: 10,
        frame_timeout_ms: 20
      },
      domains: [
        %Ogol.Hardware.Config.EtherCAT.Domain{
          id: :main,
          cycle_time_us: 1_000,
          miss_threshold: 1,
          recovery_threshold: 1
        }
      ],
      slaves: [
        %SlaveConfig{
          name: :outputs,
          driver: EL2809,
          aliases: %{ch1: :running?, ch2: :start_motor},
          process_data: {:all, :main},
          target_state: :op,
          health_poll_ms: nil
        }
      ]
    }

    {:ok, topology} =
      topology_module.start_link(hardware_configs: %{"ethercat" => hardware_config})

    on_exit(fn ->
      if Process.alive?(topology) do
        try do
          GenServer.stop(topology, :shutdown)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    pid = topology_module.machine_pid(topology, :bound_machine)

    assert {:ok, false} = Simulator.get_value(:outputs, :ch1)
    assert {:ok, false} = Simulator.get_value(:outputs, :ch2)

    assert {:ok, :ok} = Ogol.Runtime.invoke(pid, :start)

    assert_eventually(fn -> Simulator.get_value(:outputs, :ch1) == {:ok, true} end)
    assert_eventually(fn -> Simulator.get_value(:outputs, :ch2) == {:ok, true} end)
  end

  defp unique_module(prefix) do
    Module.concat([Ogol, TestSupport, :"#{prefix}#{System.unique_integer([:positive])}"])
  end

  defp boot_ethercat_master!(devices, slaves) do
    start_supervised!(
      {Simulator, devices: devices, backend: {:udp, %{host: @simulator_ip, port: 0}}}
    )

    assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: port}}} = Simulator.status()
    :ok = EthercatRuntimeHelper.ensure_started!()

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
    assert_eventually(fn -> match?(%Master.Status{lifecycle: :operational}, Master.status()) end)
    :ok
  end

  defp boot_ethercat_simulator!(devices) do
    start_supervised!(
      {Simulator, devices: devices, backend: {:udp, %{host: @simulator_ip, port: 0}}}
    )

    assert {:ok, %SimulatorStatus{backend: %Backend.Udp{}}} = Simulator.status()
    :ok
  end

  defp stop_active_topology do
    case Ogol.Topology.Registry.active_topology() do
      %{pid: pid} when is_pid(pid) ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _reason -> :ok
        end

        await_topology_clear()

      _ ->
        :ok
    end
  end

  defp await_topology_clear(attempts \\ 50)

  defp await_topology_clear(0), do: :ok

  defp await_topology_clear(attempts) do
    case Ogol.Topology.Registry.active_topology() do
      nil ->
        :ok

      _active ->
        Process.sleep(10)
        await_topology_clear(attempts - 1)
    end
  end

  defp assert_eventually(fun, attempts \\ 80)

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
