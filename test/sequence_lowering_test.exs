defmodule Ogol.SequenceLoweringTest do
  use ExUnit.Case, async: false

  alias Ogol.Sequence.Lowering
  alias Ogol.Sequence.Ref

  defmodule SuccessfulSequence do
    use Ogol.Sequence

    sequence do
      name(:sequence_success)
      topology(Ogol.TestSupport.SequenceTopology)
      meaning("Finite sequence lowering fixture")

      proc :startup do
        do_skill(:clamp, :close)
        wait(Ref.status(:clamp, :closed?), timeout: 200, fail: "clamp failed")
      end

      run(:startup)
      do_skill(:robot, :pick, when: Ref.status(:robot, :homed?))
      wait(Ref.status(:robot, :at_pick?), timeout: 200, fail: "robot stalled")
    end
  end

  defmodule TimeoutSequence do
    use Ogol.Sequence

    sequence do
      name(:sequence_timeout)
      topology(Ogol.TestSupport.SequenceTimeoutTopology)
      meaning("Timeout lowering fixture")

      do_skill(:worker, :arm)
      wait(Ref.status(:worker, :ready?), timeout: 50, fail: "worker never ready")
    end
  end

  defmodule SignalWaitSequence do
    use Ogol.Sequence

    sequence do
      name(:sequence_signal_wait)
      topology(Ogol.TestSupport.SequenceTopology)

      do_skill(:robot, :pick)
      wait(Ref.signal(:robot, :picked), signal?: true, timeout: 100, fail: "robot stalled")
    end
  end

  test "lowers a validated sequence into a working controller machine" do
    {:ok, topology} = start_topology(Ogol.TestSupport.SequenceTopology, [:clamp, :robot])
    controller_module = unique_module(:successful_sequence_runtime)

    assert {:ok, %{module: ^controller_module, source: source}} =
             Lowering.lower_to_machine_source(
               SuccessfulSequence,
               module: controller_module,
               poll_interval_ms: 10
             )

    compile_runtime_module(controller_module, source)

    {:ok, controller} =
      controller_module.start_link(signal_sink: self(), machine_id: :sequence_success_runtime)

    on_exit(fn ->
      stop_if_alive(controller)
      stop_if_alive(topology)
    end)

    assert {:ok, :ok} = Ogol.Runtime.Delivery.invoke(controller, :start)
    assert_receive {:ogol_signal, :sequence_success_runtime, :started, %{}, %{}}, 250
    assert_receive {:ogol_signal, :sequence_success_runtime, :completed, %{}, %{}}, 500

    assert %Ogol.Status{current_state: :completed, fields: fields} =
             await_status(controller_module, controller, fn
               %Ogol.Status{current_state: :completed} -> true
               _ -> false
             end)

    assert fields.phase == :completed
    assert fields.running? == false
    assert fields.failure_message == nil

    assert %Ogol.Status{facts: %{closed?: true}} =
             Ogol.TestSupport.SequenceClampMachine.status(:clamp)

    assert %Ogol.Status{facts: %{at_pick?: true, homed?: true}} =
             Ogol.TestSupport.SequenceRobotMachine.status(:robot)
  end

  test "propagates wait timeouts into a failed controller state" do
    {:ok, topology} = start_topology(Ogol.TestSupport.SequenceTimeoutTopology, [:worker])
    controller_module = unique_module(:timeout_sequence_runtime)

    assert {:ok, %{module: ^controller_module, source: source}} =
             Lowering.lower_to_machine_source(
               TimeoutSequence,
               module: controller_module,
               poll_interval_ms: 10
             )

    compile_runtime_module(controller_module, source)

    {:ok, controller} =
      controller_module.start_link(signal_sink: self(), machine_id: :sequence_timeout_runtime)

    on_exit(fn ->
      stop_if_alive(controller)
      stop_if_alive(topology)
    end)

    assert {:ok, :ok} = Ogol.Runtime.Delivery.invoke(controller, :start)
    assert_receive {:ogol_signal, :sequence_timeout_runtime, :started, %{}, %{}}, 250
    assert_receive {:ogol_signal, :sequence_timeout_runtime, :failed, %{}, %{}}, 500

    assert %Ogol.Status{current_state: :failed, fields: fields} =
             await_status(controller_module, controller, fn
               %Ogol.Status{current_state: :failed} -> true
               _ -> false
             end)

    assert fields.phase == :failed
    assert fields.running? == false
    assert fields.failure_message == "worker never ready"
  end

  test "rejects lowering sequences that still depend on signal waits" do
    assert {:error, diagnostics} = Lowering.lower_to_machine_source(SignalWaitSequence)
    assert Enum.any?(diagnostics, &String.contains?(&1, "signal waits"))
  end

  defp unique_module(suffix) do
    Module.concat(__MODULE__, :"#{suffix}_#{System.unique_integer([:positive])}")
  end

  defp compile_runtime_module(module, source) do
    modules = Code.compile_string(source)

    assert Enum.any?(modules, fn {compiled_module, _binary} -> compiled_module == module end)

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)
  end

  defp start_topology(module, names) do
    {:ok, topology} = module.start_link(signal_sink: self())

    on_exit(fn ->
      stop_if_alive(topology)
      await_registry_clear(names)
    end)

    {:ok, topology}
  end

  defp await_status(module, target, predicate, attempts \\ 50)

  defp await_status(_module, _target, _predicate, 0),
    do: flunk("sequence controller status did not converge")

  defp await_status(module, target, predicate, attempts) do
    status = module.status(target)

    if predicate.(status) do
      status
    else
      Process.sleep(10)
      await_status(module, target, predicate, attempts - 1)
    end
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
      catch_exit(GenServer.stop(pid, :shutdown))
    end

    :ok
  end

  defp stop_if_alive(_pid), do: :ok
end
