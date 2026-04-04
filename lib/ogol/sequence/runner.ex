defmodule Ogol.Sequence.Runner do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Ogol.Runtime
  alias Ogol.Runtime.Target
  alias Ogol.Sequence.Model

  @poll_interval_ms 50

  defmodule Frame do
    @moduledoc false

    defstruct [:procedure_id, :label, steps: [], index: 0]
  end

  defmodule Wait do
    @moduledoc false

    defstruct [
      :kind,
      :step,
      :poll_ref,
      :deadline_ref,
      :machine,
      :signal
    ]
  end

  defmodule State do
    @moduledoc false

    defstruct [
      :run_id,
      :sequence_id,
      :sequence_module,
      :deployment_id,
      :topology_module,
      :topology_scope,
      :owner,
      :sequence,
      :procedures,
      :started_at,
      :finished_at,
      :current_procedure,
      :current_step_id,
      :current_step_label,
      :last_error,
      stack: [],
      wait: nil
    ]
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    run_id = Keyword.fetch!(opts, :run_id)

    %{
      id: {__MODULE__, run_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec via(atom()) :: {:via, Registry, {module(), term()}}
  def via(topology_scope) when is_atom(topology_scope) do
    {:via, Registry, {Ogol.Topology.Registry, {:sequence_run, topology_scope}}}
  end

  @spec whereis(atom()) :: pid() | nil
  def whereis(topology_scope) when is_atom(topology_scope) do
    case Registry.lookup(Ogol.Topology.Registry, {:sequence_run, topology_scope}) do
      [{pid, _value}] when is_pid(pid) -> pid
      [] -> nil
    end
  end

  @spec snapshot(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  catch
    :exit, reason -> {:error, reason}
  end

  @spec cancel(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def cancel(server) do
    GenServer.call(server, :cancel)
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    %Model{sequence: sequence} = model = Keyword.fetch!(opts, :sequence_model)

    state = %State{
      run_id: Keyword.fetch!(opts, :run_id),
      sequence_id: Keyword.fetch!(opts, :sequence_id),
      sequence_module: Keyword.fetch!(opts, :sequence_module),
      deployment_id: Keyword.fetch!(opts, :deployment_id),
      topology_module: Keyword.fetch!(opts, :topology_module),
      topology_scope: Keyword.fetch!(opts, :topology_scope),
      owner: Keyword.fetch!(opts, :owner),
      sequence: sequence,
      procedures: Map.new(sequence.procedures, &{&1.id, &1}),
      started_at: System.system_time(:millisecond),
      stack: [%Frame{procedure_id: :root, label: "root", steps: sequence.root, index: 0}]
    }

    if not match?(%Model{}, model) do
      {:stop, :invalid_sequence_model}
    else
      :ok = subscribe_signal_refs(model)
      {:ok, state, {:continue, :start}}
    end
  end

  @impl true
  def handle_continue(:start, %State{} = state) do
    notify_owner(state, :started, snapshot_payload(state))
    drive(state)
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, {:ok, snapshot_payload(state)}, state}
  end

  def handle_call(:cancel, _from, %State{} = state) do
    snapshot =
      state
      |> finish_with(nil)
      |> snapshot_payload()

    {:stop, :normal, {:ok, snapshot}, state}
  end

  @impl true
  def handle_info(
        {:sequence_wait_poll, ref},
        %State{wait: %Wait{kind: :status, poll_ref: ref} = wait} = state
      ) do
    state = %State{state | wait: nil}
    continue_status_wait(state, wait.step)
  end

  def handle_info(
        {:sequence_wait_deadline, ref},
        %State{wait: %Wait{deadline_ref: ref, step: step}} = state
      ) do
    state = %State{state | wait: nil}
    fail_run(state, timeout_message(step.on_timeout, step_label(step)))
  end

  def handle_info(
        {:ogol_signal, machine, signal, _data, _meta},
        %State{wait: %Wait{kind: :signal, machine: machine, signal: signal, step: step}} = state
      ) do
    state = %State{state | wait: nil}

    with :ok <- check_step_preconditions(state, step) do
      drive(state)
    else
      {:error, reason} ->
        fail_run(state, reason)
    end
  end

  def handle_info(_message, %State{} = state) do
    {:noreply, state}
  end

  defp drive(%State{} = state) do
    case next_step(state) do
      {:complete, next_state} ->
        complete_run(next_state)

      {:step, next_state, frame, step} ->
        execute_step(next_state, frame, step)
    end
  end

  defp next_step(%State{} = state) do
    stack = trim_completed_frames(state.stack)
    next_state = %State{state | stack: stack}

    case stack do
      [] ->
        {:complete, next_state}

      [%Frame{} = frame | _rest] ->
        {:step, next_state, frame, Enum.at(frame.steps, frame.index)}
    end
  end

  defp trim_completed_frames([%Frame{steps: steps, index: index} | rest])
       when is_list(steps) and index >= length(steps) do
    trim_completed_frames(rest)
  end

  defp trim_completed_frames(stack), do: stack

  defp execute_step(%State{} = state, %Frame{} = frame, %Model.Step{} = step) do
    state =
      state
      |> enter_step(frame, step)
      |> tap(&notify_owner(&1, :advanced, snapshot_payload(&1)))

    case step.kind do
      :do_skill ->
        execute_do_skill(advance_frame(state), step)

      :wait_status ->
        continue_status_wait(advance_frame(state), step)

      :wait_signal ->
        continue_signal_wait(advance_frame(state), step)

      :run_procedure ->
        execute_run_procedure(advance_frame(state), step)

      :repeat ->
        execute_repeat(state, step)

      :fail ->
        fail_run(state, step.message || step_label(step))
    end
  end

  defp execute_do_skill(
         %State{} = state,
         %Model.Step{target: %Model.SkillRef{machine: machine, skill: skill}} = step
       ) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step),
         {:ok, _result} <-
           Runtime.invoke(machine, skill, %{}, timeout: timeout_value(step.timeout)) do
      drive(state)
    else
      {:error, reason} ->
        fail_run(state, reason_message(reason, "#{label} failed"))
    end
  end

  defp continue_status_wait(%State{} = state, %Model.Step{} = step) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step),
         {:ok, satisfied?} <- eval_boolean(step.condition) do
      if satisfied? do
        drive(state)
      else
        {:noreply, schedule_status_wait(state, step)}
      end
    else
      {:error, reason} ->
        fail_run(state, reason_message(reason, "#{label} failed"))
    end
  end

  defp continue_signal_wait(
         %State{} = state,
         %Model.Step{condition: %Model.SignalRef{machine: machine, item: signal}} = step
       ) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step),
         {:ok, _runtime} <- Target.resolve_machine_runtime(machine) do
      {:noreply, schedule_signal_wait(state, step, machine, signal)}
    else
      {:error, reason} ->
        fail_run(state, reason_message(reason, "#{label} failed"))
    end
  end

  defp execute_run_procedure(%State{} = state, %Model.Step{procedure: procedure_id} = step) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step),
         {:ok, procedure} <- Map.fetch(state.procedures, procedure_id) do
      case procedure.body do
        [] ->
          drive(state)

        body ->
          state
          |> push_frame(Atom.to_string(procedure.name), procedure.id, body)
          |> drive()
      end
    else
      :error ->
        fail_run(state, "#{label} failed: unknown procedure #{inspect(procedure_id)}")

      {:error, reason} ->
        fail_run(state, reason_message(reason, "#{label} failed"))
    end
  end

  defp execute_repeat(%State{} = state, %Model.Step{body: body} = step) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step) do
      case body || [] do
        [] ->
          fail_run(state, "#{label} failed: repeat block is empty")

        steps ->
          state
          |> push_frame("#{state.current_procedure || "root"}::repeat", step.id, steps)
          |> drive()
      end
    else
      {:error, reason} ->
        fail_run(state, reason_message(reason, "#{label} failed"))
    end
  end

  defp complete_run(%State{} = state) do
    final_state = finish_with(state, nil)
    notify_owner(final_state, :completed, snapshot_payload(final_state))
    {:stop, :normal, final_state}
  end

  defp fail_run(%State{} = state, message) when is_binary(message) do
    final_state = finish_with(state, message)
    notify_owner(final_state, :failed, snapshot_payload(final_state))
    {:stop, :normal, final_state}
  end

  defp schedule_status_wait(%State{} = state, %Model.Step{} = step) do
    poll_ref = make_ref()
    Process.send_after(self(), {:sequence_wait_poll, poll_ref}, @poll_interval_ms)

    deadline_ref =
      case step.timeout do
        %Model.TimeoutSpec{duration_ms: duration_ms}
        when is_integer(duration_ms) and duration_ms >= 0 ->
          ref = make_ref()
          Process.send_after(self(), {:sequence_wait_deadline, ref}, duration_ms)
          ref

        _other ->
          nil
      end

    %State{
      state
      | wait: %Wait{kind: :status, step: step, poll_ref: poll_ref, deadline_ref: deadline_ref}
    }
  end

  defp schedule_signal_wait(%State{} = state, %Model.Step{} = step, machine, signal) do
    deadline_ref =
      case step.timeout do
        %Model.TimeoutSpec{duration_ms: duration_ms}
        when is_integer(duration_ms) and duration_ms >= 0 ->
          ref = make_ref()
          Process.send_after(self(), {:sequence_wait_deadline, ref}, duration_ms)
          ref

        _other ->
          nil
      end

    %State{
      state
      | wait: %Wait{
          kind: :signal,
          step: step,
          machine: machine,
          signal: signal,
          deadline_ref: deadline_ref
        }
    }
  end

  defp check_step_preconditions(%State{} = state, %Model.Step{} = step) do
    with :ok <- check_invariants(state.sequence.invariants),
         :ok <- check_guard(step.guard, precondition_message(step_label(step))) do
      :ok
    end
  end

  defp check_invariants(invariants) when is_list(invariants) do
    Enum.reduce_while(invariants, :ok, fn invariant, :ok ->
      case eval_boolean(invariant.condition) do
        {:ok, true} ->
          {:cont, :ok}

        {:ok, false} ->
          {:halt, {:error, invariant_message(invariant)}}

        {:error, reason} ->
          {:halt, {:error, reason_message(reason, invariant_message(invariant))}}
      end
    end)
  end

  defp check_guard(nil, _message), do: :ok

  defp check_guard(expr, message) do
    case eval_boolean(expr) do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, message}
      {:error, reason} -> {:error, reason_message(reason, message)}
    end
  end

  defp eval_boolean(value) when is_boolean(value), do: {:ok, value}

  defp eval_boolean(%Model.StatusRef{} = ref) do
    case eval_value(ref) do
      {:ok, value} -> {:ok, value == true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp eval_boolean(%Model.TopologyRef{} = ref) do
    case eval_value(ref) do
      {:ok, value} -> {:ok, value == true}
      {:error, reason} -> {:error, reason}
    end
  end

  defp eval_boolean(%Model.Expr.Not{expr: expr}) do
    case eval_boolean(expr) do
      {:ok, value} -> {:ok, not value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp eval_boolean(%Model.Expr.And{left: left, right: right}) do
    with {:ok, left_value} <- eval_boolean(left),
         {:ok, right_value} <- eval_boolean(right) do
      {:ok, left_value and right_value}
    end
  end

  defp eval_boolean(%Model.Expr.Or{left: left, right: right}) do
    with {:ok, left_value} <- eval_boolean(left),
         {:ok, right_value} <- eval_boolean(right) do
      {:ok, left_value or right_value}
    end
  end

  defp eval_boolean(%Model.Expr.Compare{} = expr) do
    with {:ok, left_value} <- eval_value(expr.left),
         {:ok, right_value} <- eval_value(expr.right) do
      {:ok, compare_values(expr.op, left_value, right_value)}
    end
  end

  defp eval_boolean(other), do: {:error, {:unsupported_boolean_expr, other}}

  defp eval_value(value)
       when is_boolean(value) or is_integer(value) or is_float(value) or is_binary(value),
       do: {:ok, value}

  defp eval_value(%Model.StatusRef{machine: machine, item: item}) do
    status_value(machine, item)
  end

  defp eval_value(%Model.TopologyRef{scope: :system, item: :estop}), do: {:ok, false}

  defp eval_value(%Model.Expr.Compare{} = expr) do
    eval_boolean(expr)
  end

  defp eval_value(other), do: {:error, {:unsupported_value_expr, other}}

  defp status_value(machine, item) do
    case Target.resolve_machine_runtime(machine) do
      {:ok, %{data: %Ogol.Runtime.Data{} = data}} ->
        {:ok, pick_data_item(data, item)}

      {:error, _reason} ->
        {:error, {:machine_unavailable, machine}}
    end
  end

  defp pick_data_item(data, item) do
    cond do
      Map.has_key?(data.facts, item) -> Map.get(data.facts, item)
      Map.has_key?(data.outputs, item) -> Map.get(data.outputs, item)
      Map.has_key?(data.fields, item) -> Map.get(data.fields, item)
      true -> nil
    end
  end

  defp compare_values(op, left, right) do
    try do
      case op do
        :== -> left == right
        :!= -> left != right
        :< -> left < right
        :<= -> left <= right
        :> -> left > right
        :>= -> left >= right
      end
    rescue
      _error -> false
    end
  end

  defp enter_step(%State{} = state, %Frame{} = frame, %Model.Step{} = step) do
    %State{
      state
      | current_procedure: frame.label,
        current_step_id: step.id,
        current_step_label: step_label(step)
    }
  end

  defp advance_frame(%State{stack: [%Frame{} = frame | rest]} = state) do
    %State{state | stack: [%Frame{frame | index: frame.index + 1} | rest]}
  end

  defp push_frame(%State{} = state, label, procedure_id, steps)
       when is_binary(label) and is_list(steps) do
    frame = %Frame{procedure_id: procedure_id, label: label, steps: steps, index: 0}
    %State{state | stack: [frame | state.stack]}
  end

  defp finish_with(%State{} = state, last_error) do
    %State{
      state
      | wait: nil,
        last_error: last_error,
        finished_at: System.system_time(:millisecond)
    }
  end

  defp snapshot_payload(%State{} = state) do
    %{
      sequence_id: state.sequence_id,
      sequence_module: state.sequence_module,
      run_id: state.run_id,
      deployment_id: state.deployment_id,
      topology_module: state.topology_module,
      current_procedure: state.current_procedure,
      current_step_id: state.current_step_id,
      current_step_label: state.current_step_label,
      started_at: state.started_at,
      finished_at: Map.get(state, :finished_at),
      last_error: state.last_error
    }
  end

  defp notify_owner(%State{owner: owner} = state, event, snapshot)
       when is_pid(owner) and event in [:started, :advanced, :completed, :failed] do
    send(owner, {:sequence_progress, self(), event, snapshot})
    state
  end

  defp step_label(%Model.Step{
         projection: projection,
         target: %Model.SkillRef{machine: machine, skill: skill}
       })
       when is_map(projection) do
    Map.get(projection, :label) || "Invoke #{machine}.#{skill}"
  end

  defp step_label(%Model.Step{projection: projection, condition: condition})
       when is_map(projection) do
    Map.get(projection, :label) || inspect(condition)
  end

  defp step_label(%Model.Step{projection: projection, procedure: procedure})
       when is_map(projection) do
    Map.get(projection, :label) || "Run #{inspect(procedure)}"
  end

  defp step_label(%Model.Step{projection: projection, message: message})
       when is_map(projection) do
    Map.get(projection, :label) || message || "Fail"
  end

  defp invariant_message(%Model.Invariant{meaning: meaning})
       when is_binary(meaning) and byte_size(meaning) > 0,
       do: meaning

  defp invariant_message(%Model.Invariant{id: id}), do: "Invariant violated: #{id}"

  defp timeout_value(nil), do: 5_000
  defp timeout_value(%Model.TimeoutSpec{duration_ms: duration_ms}), do: duration_ms

  defp timeout_message(%Model.Failure{message: message}, _label) when is_binary(message),
    do: message

  defp timeout_message(_failure, label), do: "#{label} timed out"
  defp precondition_message(label), do: "#{label} precondition was false"

  defp subscribe_signal_refs(%Model{sequence: %Model.SequenceDefinition{} = sequence}) do
    sequence.root
    |> collect_signal_refs(MapSet.new())
    |> then(fn refs ->
      Enum.reduce(sequence.procedures, refs, fn procedure, acc ->
        collect_signal_refs(procedure.body || [], acc)
      end)
    end)
    |> Enum.each(fn {machine, signal} ->
      :ok = Ogol.Machine.Registry.subscribe_signal(machine, signal)
    end)

    :ok
  end

  defp collect_signal_refs(steps, refs) when is_list(steps) do
    Enum.reduce(steps, refs, fn
      %Model.Step{kind: :wait_signal, condition: %Model.SignalRef{machine: machine, item: signal}},
      acc ->
        MapSet.put(acc, {machine, signal})

      %Model.Step{kind: :repeat, body: body}, acc when is_list(body) ->
        collect_signal_refs(body, acc)

      _step, acc ->
        acc
    end)
  end

  defp reason_message(message, _prefix) when is_binary(message), do: message

  defp reason_message({:machine_unavailable, machine}, prefix),
    do: "#{prefix}: machine #{inspect(machine)} is unavailable"

  defp reason_message({:unsupported_boolean_expr, expr}, prefix),
    do: "#{prefix}: unsupported boolean expression #{inspect(expr)}"

  defp reason_message({:unsupported_value_expr, expr}, prefix),
    do: "#{prefix}: unsupported value expression #{inspect(expr)}"

  defp reason_message(reason, prefix), do: "#{prefix}: #{inspect(reason)}"
end
