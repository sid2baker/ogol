defmodule Ogol.Sequence.Runner do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Ogol.Runtime.CommandGateway
  alias Ogol.Runtime.Target
  alias Ogol.Sequence.Model

  @poll_interval_ms 50
  @drive_message :sequence_drive

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
      :command_dispatcher,
      :run_id,
      :sequence_id,
      :sequence_module,
      :policy,
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
      :fault_source,
      :fault_recoverability,
      :fault_scope,
      :pending_pause,
      :pending_abort,
      :resume_from_boundary,
      :resume_stack,
      :resume_blockers,
      :resumable?,
      :run_generation,
      :cycle_count,
      paused?: false,
      started?: false,
      begin_event: :started,
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

  @spec begin(GenServer.server()) :: :ok | {:error, term()}
  def begin(server) do
    GenServer.cast(server, :begin_run)
    :ok
  catch
    :exit, reason -> {:error, reason}
  end

  @spec request_abort(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def request_abort(server, opts \\ []) do
    GenServer.cast(server, {:request_abort, opts})
    :ok
  catch
    :exit, reason -> {:error, reason}
  end

  @spec request_pause(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def request_pause(server, opts \\ []) do
    GenServer.cast(server, {:request_pause, opts})
    :ok
  catch
    :exit, reason -> {:error, reason}
  end

  @spec request_resume(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def request_resume(server, opts \\ []) do
    GenServer.cast(server, {:request_resume, opts})
    :ok
  catch
    :exit, reason -> {:error, reason}
  end

  @spec stop(GenServer.server()) :: :ok | {:error, term()}
  def stop(server) do
    GenServer.stop(server, :shutdown)
    :ok
  catch
    :exit, reason -> {:error, reason}
  end

  @impl true
  def init(opts) do
    %Model{sequence: sequence} = model = Keyword.fetch!(opts, :sequence_model)

    state =
      %State{
        command_dispatcher: Keyword.get(opts, :command_dispatcher, &CommandGateway.invoke/4),
        run_id: Keyword.fetch!(opts, :run_id),
        sequence_id: Keyword.fetch!(opts, :sequence_id),
        sequence_module: Keyword.fetch!(opts, :sequence_module),
        policy: Keyword.get(opts, :policy, :once),
        deployment_id: Keyword.fetch!(opts, :deployment_id),
        topology_module: Keyword.fetch!(opts, :topology_module),
        topology_scope: Keyword.fetch!(opts, :topology_scope),
        owner: Keyword.fetch!(opts, :owner),
        sequence: sequence,
        procedures: Map.new(sequence.procedures, &{&1.id, &1}),
        started_at: System.system_time(:millisecond),
        pending_pause: nil,
        pending_abort: nil,
        resume_from_boundary: nil,
        resume_stack: nil,
        resume_blockers: [:no_committed_boundary],
        resumable?: false,
        run_generation: Keyword.fetch!(opts, :run_generation),
        cycle_count: 0,
        stack: initial_stack(sequence)
      }
      |> apply_resume_snapshot(Keyword.get(opts, :resume_snapshot))

    if not match?(%Model{}, model) do
      {:stop, :invalid_sequence_model}
    else
      :ok = subscribe_signal_refs(model)
      {:ok, state}
    end
  end

  @impl true
  def handle_cast(:begin_run, %State{started?: true} = state) do
    {:noreply, state}
  end

  def handle_cast(:begin_run, %State{} = state) do
    state = %State{state | started?: true}
    notify_owner(state, state.begin_event, snapshot_payload(state))
    {:noreply, continue_drive(state)}
  end

  def handle_cast({:request_abort, opts}, %State{} = state) do
    next_state = request_abort_state(state, opts)

    if abort_ready?(next_state) do
      abort_run(next_state)
    else
      {:noreply, next_state}
    end
  end

  def handle_cast({:request_pause, _opts}, %State{paused?: true} = state) do
    {:noreply, state}
  end

  def handle_cast({:request_pause, opts}, %State{} = state) do
    next_state = request_pause_state(state, opts)

    if pause_ready?(next_state) do
      pause_run(next_state)
    else
      {:noreply, next_state}
    end
  end

  def handle_cast({:request_resume, _opts}, %State{paused?: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:request_resume, _opts}, %State{} = state) do
    resume_run(state)
  end

  @impl true
  def handle_call(:snapshot, _from, %State{} = state) do
    {:reply, {:ok, snapshot_payload(state)}, state}
  end

  @impl true
  def handle_info(@drive_message, %State{paused?: true} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:sequence_wait_poll, ref},
        %State{paused?: true, wait: %Wait{kind: :status, poll_ref: ref}} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:sequence_wait_deadline, ref},
        %State{paused?: true, wait: %Wait{deadline_ref: ref}} = state
      ) do
    {:noreply, state}
  end

  def handle_info(
        {:ogol_signal, machine, signal, _data, _meta},
        %State{
          paused?: true,
          wait: %Wait{kind: :signal, machine: machine, signal: signal}
        } = state
      ) do
    {:noreply, state}
  end

  @impl true
  def handle_info(@drive_message, %State{} = state) do
    if abort_ready?(state) do
      abort_run(state)
    else
      if pause_ready?(state) do
        pause_run(state)
      else
        drive(state)
      end
    end
  end

  @impl true
  def handle_info(
        {:sequence_wait_poll, ref},
        %State{wait: %Wait{kind: :status, poll_ref: ref} = wait} = state
      ) do
    state = %State{state | wait: nil}
    continue_status_wait(state, wait.step, wait.deadline_ref)
  end

  def handle_info(
        {:sequence_wait_deadline, ref},
        %State{wait: %Wait{kind: :delay, deadline_ref: ref, step: step}} = state
      ) do
    state = %State{state | wait: nil}
    {:noreply, state |> commit_boundary(step) |> continue_drive()}
  end

  def handle_info(
        {:sequence_wait_deadline, ref},
        %State{wait: %Wait{deadline_ref: ref, step: step}} = state
      ) do
    state = %State{state | wait: nil}

    fail_run(state, timeout_message(step.on_timeout, step_label(step)),
      fault_source: :sequence_logic,
      fault_recoverability: :abort_required,
      fault_scope: :step_local
    )
  end

  def handle_info(
        {:ogol_signal, machine, signal, _data, _meta},
        %State{wait: %Wait{kind: :signal, machine: machine, signal: signal, step: step}} = state
      ) do
    state = %State{state | wait: nil}

    with :ok <- check_step_preconditions(state, step) do
      state
      |> commit_boundary(step)
      |> continue_drive()
      |> then(&{:noreply, &1})
    else
      {:error, reason} ->
        fail_run_reason(state, reason, step_label(step))
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

      :delay ->
        execute_delay(advance_frame(state), step)

      :repeat ->
        execute_repeat(state, step)

      :fail ->
        fail_run(state, step.message || step_label(step),
          fault_source: :sequence_logic,
          fault_recoverability: :abort_required,
          fault_scope: :run_wide
        )
    end
  end

  defp execute_do_skill(
         %State{} = state,
         %Model.Step{target: %Model.SkillRef{machine: machine, skill: skill}} = step
       ) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step),
         {:ok, _result} <-
           state.command_dispatcher.(
             machine,
             skill,
             %{},
             command_class: {:sequence_run, state.run_id},
             timeout: timeout_value(step.timeout)
           ) do
      {:noreply, state |> commit_boundary(step) |> continue_drive()}
    else
      {:error, reason} ->
        fail_run_reason(state, reason, label)
    end
  end

  defp continue_status_wait(%State{} = state, %Model.Step{} = step, deadline_ref \\ nil) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step),
         {:ok, satisfied?} <- eval_boolean(step.condition) do
      if satisfied? do
        {:noreply, state |> commit_boundary(step) |> continue_drive()}
      else
        {:noreply, schedule_status_wait(state, step, deadline_ref)}
      end
    else
      {:error, reason} ->
        fail_run_reason(state, reason, label)
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
        fail_run_reason(state, reason, label)
    end
  end

  defp execute_run_procedure(%State{} = state, %Model.Step{procedure: procedure_id} = step) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step),
         {:ok, procedure} <- Map.fetch(state.procedures, procedure_id) do
      case procedure.body do
        [] ->
          {:noreply, state |> commit_boundary(step) |> continue_drive()}

        body ->
          {:noreply,
           state
           |> commit_boundary(step)
           |> push_frame(Atom.to_string(procedure.name), procedure.id, body)
           |> continue_drive()}
      end
    else
      :error ->
        fail_run(state, "#{label} failed: unknown procedure #{inspect(procedure_id)}",
          fault_source: :sequence_logic,
          fault_recoverability: :abort_required,
          fault_scope: :run_wide
        )

      {:error, reason} ->
        fail_run_reason(state, reason, label)
    end
  end

  defp execute_delay(%State{} = state, %Model.Step{duration_ms: duration_ms} = step)
       when is_integer(duration_ms) and duration_ms >= 0 do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step) do
      {:noreply, schedule_delay(state, step)}
    else
      {:error, reason} ->
        fail_run_reason(state, reason, label)
    end
  end

  defp execute_repeat(%State{} = state, %Model.Step{body: body} = step) do
    label = step_label(step)

    with :ok <- check_step_preconditions(state, step) do
      case body || [] do
        [] ->
          fail_run(state, "#{label} failed: repeat block is empty",
            fault_source: :sequence_logic,
            fault_recoverability: :abort_required,
            fault_scope: :run_wide
          )

        steps ->
          {:noreply,
           state
           |> push_frame("#{state.current_procedure || "root"}::repeat", step.id, steps)
           |> continue_drive()}
      end
    else
      {:error, reason} ->
        fail_run_reason(state, reason, label)
    end
  end

  defp complete_run(%State{} = state) do
    case state.policy do
      :cycle ->
        continue_cycle(state)

      :once ->
        final_state = finish_with(state, nil, terminal?: true)
        notify_owner(final_state, :completed, snapshot_payload(final_state))
        {:stop, :normal, final_state}
    end
  end

  defp fail_run(%State{} = state, message, opts) when is_binary(message) and is_list(opts) do
    final_state = finish_with(state, message, Keyword.put(opts, :terminal?, true))
    notify_owner(final_state, :failed, snapshot_payload(final_state))
    {:stop, :normal, final_state}
  end

  defp fail_run_reason(%State{} = state, reason, prefix) when is_binary(prefix) do
    classification = classify_failure_reason(reason)
    fail_run(state, reason_message(reason, "#{prefix} failed"), classification)
  end

  defp schedule_status_wait(%State{} = state, %Model.Step{} = step, deadline_ref) do
    poll_ref = make_ref()
    Process.send_after(self(), {:sequence_wait_poll, poll_ref}, @poll_interval_ms)

    deadline_ref =
      cond do
        is_reference(deadline_ref) ->
          deadline_ref

        true ->
          case step.timeout do
            %Model.TimeoutSpec{duration_ms: duration_ms}
            when is_integer(duration_ms) and duration_ms >= 0 ->
              ref = make_ref()
              Process.send_after(self(), {:sequence_wait_deadline, ref}, duration_ms)
              ref

            _other ->
              nil
          end
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

  defp schedule_delay(%State{} = state, %Model.Step{duration_ms: duration_ms} = step) do
    ref = make_ref()
    Process.send_after(self(), {:sequence_wait_deadline, ref}, duration_ms)

    %State{
      state
      | wait: %Wait{
          kind: :delay,
          step: step,
          deadline_ref: ref
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

  defp commit_boundary(%State{} = state, %Model.Step{id: step_id}) when is_binary(step_id) do
    %State{
      state
      | resume_from_boundary: step_id,
        resume_stack: state.stack,
        resume_blockers: [],
        resumable?: true
    }
  end

  defp commit_boundary(%State{} = state, _step), do: state

  defp continue_drive(%State{} = state) do
    send(self(), @drive_message)
    state
  end

  defp request_abort_state(%State{} = state, opts) when is_list(opts) do
    %State{
      state
      | pending_abort: %{
          requested_by: Keyword.get(opts, :requested_by, :operator),
          requested_at: Keyword.get(opts, :requested_at, DateTime.utc_now())
        }
    }
  end

  defp request_pause_state(%State{} = state, opts) when is_list(opts) do
    %State{
      state
      | pending_pause: %{
          requested_by: Keyword.get(opts, :requested_by, :operator),
          requested_at: Keyword.get(opts, :requested_at, DateTime.utc_now())
        }
    }
  end

  defp abort_ready?(%State{pending_abort: nil}), do: false
  defp abort_ready?(%State{wait: %Wait{}}), do: true
  defp abort_ready?(%State{started?: true}), do: true
  defp abort_ready?(_state), do: false

  defp pause_ready?(%State{pending_pause: nil}), do: false
  defp pause_ready?(%State{paused?: true}), do: false
  defp pause_ready?(%State{wait: %Wait{}}), do: false
  defp pause_ready?(%State{started?: true}), do: true
  defp pause_ready?(_state), do: false

  defp pause_run(%State{} = state) do
    final_state =
      %State{
        state
        | pending_pause: nil,
          paused?: true,
          fault_source: nil,
          fault_recoverability: nil,
          fault_scope: nil,
          finished_at: nil
      }

    notify_owner(final_state, :paused, snapshot_payload(final_state))
    {:noreply, final_state}
  end

  defp resume_run(%State{resumable?: true, resume_blockers: []} = state) do
    next_state =
      %State{
        state
        | paused?: false,
          fault_source: nil,
          fault_recoverability: nil,
          fault_scope: nil,
          finished_at: nil
      }

    notify_owner(next_state, :resumed, snapshot_payload(next_state))
    {:noreply, continue_drive(next_state)}
  end

  defp resume_run(%State{} = state), do: {:noreply, state}

  defp abort_run(%State{} = state) do
    final_state = finish_with(state, nil, terminal?: true)
    notify_owner(final_state, :aborted, snapshot_payload(final_state))
    {:stop, :normal, final_state}
  end

  defp finish_with(%State{} = state, last_error, opts) do
    terminal? = Keyword.get(opts, :terminal?, false)

    {resumable?, resume_blockers} =
      if terminal? do
        {false, [:terminal_state]}
      else
        {state.resumable?, state.resume_blockers}
      end

    %State{
      state
      | wait: nil,
        pending_pause: nil,
        pending_abort: nil,
        paused?: false,
        last_error: last_error,
        fault_source: Keyword.get(opts, :fault_source),
        fault_recoverability: Keyword.get(opts, :fault_recoverability),
        fault_scope: Keyword.get(opts, :fault_scope),
        finished_at: System.system_time(:millisecond),
        resumable?: resumable?,
        resume_blockers: resume_blockers
    }
  end

  defp snapshot_payload(%State{} = state) do
    %{
      sequence_id: state.sequence_id,
      sequence_module: state.sequence_module,
      run_id: state.run_id,
      policy: state.policy,
      cycle_count: state.cycle_count,
      fault_source: state.fault_source,
      fault_recoverability: state.fault_recoverability,
      fault_scope: state.fault_scope,
      resumable?: state.resumable?,
      resume_from_boundary: state.resume_from_boundary,
      resume_stack: state.resume_stack,
      resume_blockers: List.wrap(state.resume_blockers),
      run_generation: state.run_generation,
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
       when is_pid(owner) and
              event in [:started, :advanced, :paused, :resumed, :completed, :failed, :aborted] do
    send(owner, {:sequence_progress, self(), event, snapshot})
    state
  end

  defp apply_resume_snapshot(%State{} = state, nil), do: state

  defp apply_resume_snapshot(%State{} = state, snapshot) when is_map(snapshot) do
    resume_stack = Map.get(snapshot, :resume_stack)

    if is_list(resume_stack) and Enum.all?(resume_stack, &match?(%Frame{}, &1)) do
      %State{
        state
        | started_at: Map.get(snapshot, :started_at, state.started_at),
          current_procedure: Map.get(snapshot, :current_procedure),
          current_step_id: Map.get(snapshot, :current_step_id),
          current_step_label: Map.get(snapshot, :current_step_label),
          resume_from_boundary: Map.get(snapshot, :resume_from_boundary),
          resume_stack: resume_stack,
          resume_blockers: List.wrap(Map.get(snapshot, :resume_blockers, [])),
          resumable?: Map.get(snapshot, :resumable?, false),
          policy: Map.get(snapshot, :policy, state.policy),
          run_generation: Map.get(snapshot, :run_generation, state.run_generation),
          cycle_count: Map.get(snapshot, :cycle_count, state.cycle_count),
          fault_source: nil,
          fault_recoverability: nil,
          fault_scope: nil,
          begin_event: :resumed,
          stack: resume_stack
      }
    else
      state
    end
  end

  defp continue_cycle(%State{} = state) do
    next_cycle = state.cycle_count + 1
    cycle_boundary = cycle_boundary_id(state, next_cycle)
    next_stack = initial_stack(state.sequence)

    boundary_state =
      %State{
        state
        | cycle_count: next_cycle,
          current_procedure: "cycle",
          current_step_id: cycle_boundary,
          current_step_label: "Cycle boundary",
          resume_from_boundary: cycle_boundary,
          resume_stack: next_stack,
          resume_blockers: [],
          resumable?: true,
          fault_source: nil,
          fault_recoverability: nil,
          fault_scope: nil,
          last_error: nil,
          wait: nil,
          stack: next_stack
      }

    notify_owner(boundary_state, :advanced, snapshot_payload(boundary_state))

    cond do
      abort_ready?(boundary_state) ->
        abort_run(boundary_state)

      pause_ready?(boundary_state) ->
        pause_run(boundary_state)

      true ->
        {:noreply, continue_drive(boundary_state)}
    end
  end

  defp initial_stack(%Model.SequenceDefinition{root: root}) when is_list(root) do
    [%Frame{procedure_id: :root, label: "root", steps: root, index: 0}]
  end

  defp cycle_boundary_id(%State{sequence: %Model.SequenceDefinition{id: id}}, next_cycle)
       when is_binary(id) and is_integer(next_cycle) do
    "#{id}.cycle_boundary.#{next_cycle}"
  end

  defp cycle_boundary_id(%State{sequence_id: sequence_id}, next_cycle)
       when is_binary(sequence_id) and is_integer(next_cycle) do
    "#{sequence_id}.cycle_boundary.#{next_cycle}"
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

  defp classify_failure_reason({:machine_unavailable, _machine}) do
    [
      fault_source: :external_runtime,
      fault_recoverability: :abort_required,
      fault_scope: :runtime_wide
    ]
  end

  defp classify_failure_reason({:unsupported_boolean_expr, _expr}) do
    [
      fault_source: :sequence_logic,
      fault_recoverability: :abort_required,
      fault_scope: :run_wide
    ]
  end

  defp classify_failure_reason({:unsupported_value_expr, _expr}) do
    [
      fault_source: :sequence_logic,
      fault_recoverability: :abort_required,
      fault_scope: :run_wide
    ]
  end

  defp classify_failure_reason(_reason) do
    [
      fault_source: :sequence_logic,
      fault_recoverability: :abort_required,
      fault_scope: :run_wide
    ]
  end
end
