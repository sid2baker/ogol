defmodule Ogol.SequenceRunnerTest do
  use ExUnit.Case, async: false

  alias Ogol.Sequence.Ref
  alias Ogol.Sequence.Runtime
  alias Ogol.Topology
  alias Ogol.Topology.Runtime, as: TopologyRuntime

  defmodule SignalPulseMachine do
    use Ogol.Machine

    machine do
      name(:signal_pulse)
      meaning("Delayed signal fixture")
    end

    boundary do
      request(:arm)
      fact(:armed?, :boolean, default: false, public?: true)
      signal(:armed)
    end

    states do
      state :idle do
        initial?(true)
        set_fact(:armed?, false)
      end

      state :arming do
        set_fact(:armed?, false)
        state_timeout(:arm_done, 20)
      end

      state :armed do
        set_fact(:armed?, true)
        signal(:armed)
      end
    end

    transitions do
      transition :idle, :arming do
        on({:request, :arm})
        reply(:ok)
      end

      transition :arming, :armed do
        on({:state_timeout, :arm_done})
      end

      transition :armed, :armed do
        on({:request, :arm})
        reply(:ok)
      end
    end
  end

  defmodule SignalSequenceTopology do
    use Ogol.Topology

    topology do
      meaning("Sequence signal runtime fixture")
    end

    machines do
      machine(:clamp, Ogol.TestSupport.SequenceClampMachine)
      machine(:pulse, SignalPulseMachine)
    end
  end

  defmodule SuccessfulSequence do
    use Ogol.Sequence

    sequence do
      name(:sequence_success)
      topology(SignalSequenceTopology)
      meaning("Finite sequence runner fixture")

      proc :startup do
        do_skill(:clamp, :close)
        wait(Ref.status(:clamp, :closed?), timeout: 200, fail: "clamp failed")
      end

      run(:startup)
      do_skill(:pulse, :arm)
      wait(Ref.signal(:pulse, :armed), signal?: true, timeout: 200, fail: "pulse stalled")
      delay(75, meaning: "Observe pulse state")
    end
  end

  defmodule TimeoutSequence do
    use Ogol.Sequence

    sequence do
      name(:sequence_timeout)
      topology(Ogol.TestSupport.SequenceTimeoutTopology)
      meaning("Timeout sequence runner fixture")

      do_skill(:worker, :arm)
      wait(Ref.status(:worker, :ready?), timeout: 100, fail: "worker never ready")
    end
  end

  defmodule BlockingAbortTopology do
    use Ogol.Topology

    topology do
      meaning("Blocking abort fixture")
    end

    machines do
      machine(:worker, Ogol.TestSupport.SlowRequestMachine)
    end
  end

  defmodule BlockingAbortSequence do
    use Ogol.Sequence

    sequence do
      name(:sequence_blocking_abort)
      topology(BlockingAbortTopology)
      meaning("Abort waits for a non-interruptible skill boundary")

      do_skill(:worker, :start)
      delay(25, meaning: "After blocking command")
    end
  end

  defmodule PauseResumeSequence do
    use Ogol.Sequence

    sequence do
      name(:sequence_pause_resume)
      topology(SignalSequenceTopology)
      meaning("Pause and resume fixture")

      do_skill(:clamp, :close)
      wait(Ref.status(:clamp, :closed?), timeout: 200, fail: "clamp failed")
      delay(200, meaning: "Pause boundary")
      delay(25, meaning: "After resume")
    end
  end

  test "runs compiled sequences directly against the active topology runtime, including signal waits" do
    {:ok, topology_pid} = start_topology(SignalSequenceTopology)
    topology_scope = Topology.scope(SignalSequenceTopology)

    assert {:ok, run_pid} =
             Runtime.start_run(
               topology_scope,
               command_dispatcher: &Ogol.Runtime.invoke/4,
               run_id: "sr_success",
               sequence_id: "sequence_success",
               sequence_module: SuccessfulSequence,
               sequence_model: SuccessfulSequence.__ogol_sequence__(),
               run_generation: "g-success",
               deployment_id: "d-success",
               topology_module: SignalSequenceTopology,
               owner: self()
             )

    assert :ok = Runtime.begin_run(topology_scope)

    on_exit(fn ->
      stop_if_alive(run_pid)
      stop_if_alive(topology_pid)
      await_registry_clear([:clamp, :pulse])
    end)

    assert_receive {:sequence_progress, ^run_pid, :started, %{sequence_id: "sequence_success"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Run startup"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Invoke clamp.close"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Wait for condition"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Invoke pulse.arm"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Wait for condition"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Observe pulse state"}},
                   250

    refute_receive {:sequence_progress, ^run_pid, :completed, _completed}, 40
    assert_receive {:sequence_progress, ^run_pid, :completed, completed}, 500

    assert completed.last_error == nil
    assert completed.sequence_module == SuccessfulSequence
    assert completed.topology_module == SignalSequenceTopology

    assert %Ogol.Machine.Status{facts: %{closed?: true}} =
             Ogol.TestSupport.SequenceClampMachine.status(:clamp)

    assert %Ogol.Machine.Status{facts: %{armed?: true}} =
             SignalPulseMachine.status(:pulse)

    assert_eventually(fn -> assert Runtime.active_run(topology_scope) == nil end)
  end

  test "supports explicit abort requests for long-running sequences" do
    {:ok, topology_pid} = start_topology(Ogol.TestSupport.SequenceTimeoutTopology)
    topology_scope = Topology.scope(Ogol.TestSupport.SequenceTimeoutTopology)

    assert {:ok, run_pid} =
             Runtime.start_run(
               topology_scope,
               command_dispatcher: &Ogol.Runtime.invoke/4,
               run_id: "sr_timeout",
               sequence_id: "sequence_timeout",
               sequence_module: TimeoutSequence,
               sequence_model: TimeoutSequence.__ogol_sequence__(),
               run_generation: "g-timeout",
               deployment_id: "d-timeout",
               topology_module: Ogol.TestSupport.SequenceTimeoutTopology,
               owner: self()
             )

    assert :ok = Runtime.begin_run(topology_scope)

    on_exit(fn ->
      stop_if_alive(run_pid)
      stop_if_alive(topology_pid)
      await_registry_clear([:worker])
    end)

    assert_receive {:sequence_progress, ^run_pid, :started, _snapshot}, 250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Invoke worker.arm"}},
                   250

    assert :ok = Runtime.request_abort(topology_scope)

    assert_receive {:sequence_progress, ^run_pid, :aborted, snapshot}, 250
    assert snapshot.sequence_id == "sequence_timeout"
    assert snapshot.finished_at
    assert snapshot.last_error == nil

    assert_eventually(fn -> assert Runtime.active_run(topology_scope) == nil end)
  end

  test "classifies terminal timeout failures as sequence-logic, abort-required, and step-local" do
    {:ok, topology_pid} = start_topology(Ogol.TestSupport.SequenceTimeoutTopology)
    topology_scope = Topology.scope(Ogol.TestSupport.SequenceTimeoutTopology)

    assert {:ok, run_pid} =
             Runtime.start_run(
               topology_scope,
               command_dispatcher: &Ogol.Runtime.invoke/4,
               run_id: "sr_timeout_fault",
               sequence_id: "sequence_timeout",
               sequence_module: TimeoutSequence,
               sequence_model: TimeoutSequence.__ogol_sequence__(),
               run_generation: "g-timeout-fault",
               deployment_id: "d-timeout-fault",
               topology_module: Ogol.TestSupport.SequenceTimeoutTopology,
               owner: self()
             )

    assert :ok = Runtime.begin_run(topology_scope)

    on_exit(fn ->
      stop_if_alive(run_pid)
      stop_if_alive(topology_pid)
      await_registry_clear([:worker])
    end)

    assert_receive {:sequence_progress, ^run_pid, :started, _snapshot}, 250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Invoke worker.arm"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Wait for condition"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :failed, snapshot}, 1_500
    assert snapshot.sequence_id == "sequence_timeout"
    assert snapshot.last_error == "worker never ready"
    assert snapshot.fault_source == :sequence_logic
    assert snapshot.fault_recoverability == :abort_required
    assert snapshot.fault_scope == :step_local
    assert snapshot.resume_blockers == [:terminal_state]

    assert_eventually(fn -> assert Runtime.active_run(topology_scope) == nil end)
  end

  test "fulfills abort only after a non-interruptible command step returns" do
    {:ok, topology_pid} = start_topology(BlockingAbortTopology)
    topology_scope = Topology.scope(BlockingAbortTopology)
    parent = self()

    dispatcher = fn machine, skill, _data, opts ->
      send(parent, {:dispatch_started, machine, skill, opts[:command_class]})
      Process.sleep(150)
      send(parent, {:dispatch_finished, machine, skill})
      {:ok, :ok}
    end

    assert {:ok, run_pid} =
             Runtime.start_run(
               topology_scope,
               command_dispatcher: dispatcher,
               run_id: "sr_blocking_abort",
               sequence_id: "sequence_blocking_abort",
               sequence_module: BlockingAbortSequence,
               sequence_model: BlockingAbortSequence.__ogol_sequence__(),
               run_generation: "g-blocking-abort",
               deployment_id: "d-blocking-abort",
               topology_module: BlockingAbortTopology,
               owner: self()
             )

    assert :ok = Runtime.begin_run(topology_scope)

    on_exit(fn ->
      stop_if_alive(run_pid)
      stop_if_alive(topology_pid)
      await_registry_clear([:worker])
    end)

    assert_receive {:sequence_progress, ^run_pid, :started, _snapshot}, 250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Invoke worker.start"}},
                   250

    assert_receive {:dispatch_started, :worker, :start, {:sequence_run, "sr_blocking_abort"}},
                   250

    assert :ok = Runtime.request_abort(topology_scope)

    refute_receive {:sequence_progress, ^run_pid, :aborted, _snapshot}, 75

    assert_receive {:dispatch_finished, :worker, :start}, 250
    assert_receive {:sequence_progress, ^run_pid, :aborted, snapshot}, 250

    assert snapshot.sequence_id == "sequence_blocking_abort"
    assert snapshot.last_error == nil
    assert snapshot.finished_at
    assert snapshot.resumable? == false
    assert snapshot.resume_blockers == [:terminal_state]

    refute_receive {:sequence_progress, ^run_pid, :completed, _snapshot}, 50
    assert_eventually(fn -> assert Runtime.active_run(topology_scope) == nil end)
  end

  test "fulfills pause at the next committed boundary and resumes from that boundary" do
    {:ok, topology_pid} = start_topology(SignalSequenceTopology)
    topology_scope = Topology.scope(SignalSequenceTopology)

    assert {:ok, run_pid} =
             Runtime.start_run(
               topology_scope,
               command_dispatcher: &Ogol.Runtime.invoke/4,
               run_id: "sr_pause_resume",
               sequence_id: "sequence_pause_resume",
               sequence_module: PauseResumeSequence,
               sequence_model: PauseResumeSequence.__ogol_sequence__(),
               run_generation: "g-pause-resume",
               deployment_id: "d-pause-resume",
               topology_module: SignalSequenceTopology,
               owner: self()
             )

    assert :ok = Runtime.begin_run(topology_scope)

    on_exit(fn ->
      stop_if_alive(run_pid)
      stop_if_alive(topology_pid)
      await_registry_clear([:clamp, :pulse])
    end)

    assert_receive {:sequence_progress, ^run_pid, :started, _snapshot}, 250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Invoke clamp.close"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Wait for condition"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Pause boundary"}},
                   250

    assert :ok = Runtime.request_pause(topology_scope)

    refute_receive {:sequence_progress, ^run_pid, :paused, _snapshot}, 100

    assert_receive {:sequence_progress, ^run_pid, :paused, paused_snapshot}, 250
    assert paused_snapshot.current_step_label == "Pause boundary"
    assert paused_snapshot.resumable? == true
    assert is_binary(paused_snapshot.resume_from_boundary)
    assert paused_snapshot.resume_blockers == []

    assert :ok = Runtime.request_resume(topology_scope)

    assert_receive {:sequence_progress, ^run_pid, :resumed, resumed_snapshot}, 250
    assert resumed_snapshot.current_step_label == "Pause boundary"
    assert resumed_snapshot.resumable? == true

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "After resume"}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :completed, completed_snapshot}, 500
    assert completed_snapshot.last_error == nil

    assert_eventually(fn -> assert Runtime.active_run(topology_scope) == nil end)
  end

  test "cycle policy loops at a durable cycle boundary instead of completing once" do
    {:ok, topology_pid} = start_topology(SignalSequenceTopology)
    topology_scope = Topology.scope(SignalSequenceTopology)

    assert {:ok, run_pid} =
             Runtime.start_run(
               topology_scope,
               command_dispatcher: &Ogol.Runtime.invoke/4,
               run_id: "sr_cycle",
               sequence_id: "sequence_success",
               sequence_module: SuccessfulSequence,
               sequence_model: SuccessfulSequence.__ogol_sequence__(),
               policy: :cycle,
               run_generation: "g-cycle",
               deployment_id: "d-cycle",
               topology_module: SignalSequenceTopology,
               owner: self()
             )

    assert :ok = Runtime.begin_run(topology_scope)

    on_exit(fn ->
      stop_if_alive(run_pid)
      stop_if_alive(topology_pid)
      await_registry_clear([:clamp, :pulse])
    end)

    assert_receive {:sequence_progress, ^run_pid, :started, %{policy: :cycle, cycle_count: 0}},
                   250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Cycle boundary", policy: :cycle, cycle_count: 1}},
                   1_500

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Run startup", policy: :cycle, cycle_count: 1}},
                   500

    refute_receive {:sequence_progress, ^run_pid, :completed, _snapshot}, 100

    assert :ok = Runtime.request_abort(topology_scope)

    assert_receive {:sequence_progress, ^run_pid, :aborted, aborted_snapshot}, 500
    assert aborted_snapshot.policy == :cycle
    assert aborted_snapshot.cycle_count >= 1

    assert_eventually(fn -> assert Runtime.active_run(topology_scope) == nil end)
  end

  defp start_topology(topology_module) do
    topology = topology_module.__ogol_topology__()
    TopologyRuntime.start(topology, signal_sink: self())
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
  end

  defp await_registry_clear(names, attempts \\ 50)

  defp await_registry_clear(_names, 0), do: :ok

  defp await_registry_clear(names, attempts) do
    if Enum.all?(names, &(Ogol.Topology.Registry.whereis(&1) == nil)) do
      :ok
    else
      Process.sleep(10)
      await_registry_clear(names, attempts - 1)
    end
  end

  defp stop_if_alive(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp stop_if_alive(_pid), do: :ok
end
