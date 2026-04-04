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

  test "runs compiled sequences directly against the active topology runtime, including signal waits" do
    {:ok, topology_pid} = start_topology(SignalSequenceTopology)
    topology_scope = Topology.scope(SignalSequenceTopology)

    assert {:ok, run_pid} =
             Runtime.start_run(
               topology_scope,
               run_id: "sr_success",
               sequence_id: "sequence_success",
               sequence_module: SuccessfulSequence,
               sequence_model: SuccessfulSequence.__ogol_sequence__(),
               deployment_id: "d-success",
               topology_module: SignalSequenceTopology,
               owner: self()
             )

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

  test "supports explicit cancellation for long-running sequences" do
    {:ok, topology_pid} = start_topology(Ogol.TestSupport.SequenceTimeoutTopology)
    topology_scope = Topology.scope(Ogol.TestSupport.SequenceTimeoutTopology)

    assert {:ok, run_pid} =
             Runtime.start_run(
               topology_scope,
               run_id: "sr_timeout",
               sequence_id: "sequence_timeout",
               sequence_module: TimeoutSequence,
               sequence_model: TimeoutSequence.__ogol_sequence__(),
               deployment_id: "d-timeout",
               topology_module: Ogol.TestSupport.SequenceTimeoutTopology,
               owner: self()
             )

    on_exit(fn ->
      stop_if_alive(run_pid)
      stop_if_alive(topology_pid)
      await_registry_clear([:worker])
    end)

    assert_receive {:sequence_progress, ^run_pid, :started, _snapshot}, 250

    assert_receive {:sequence_progress, ^run_pid, :advanced,
                    %{current_step_label: "Invoke worker.arm"}},
                   250

    assert {:ok, snapshot} = Runtime.cancel_run(topology_scope)
    assert snapshot.sequence_id == "sequence_timeout"
    assert snapshot.finished_at
    assert snapshot.last_error == nil

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
