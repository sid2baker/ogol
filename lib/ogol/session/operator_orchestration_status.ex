defmodule Ogol.Session.OperatorOrchestrationStatus do
  @moduledoc false

  alias Ogol.Session.{OperatorProcedureCatalog, SequenceRunState, State}
  alias Ogol.Topology

  @active_statuses [:starting, :running, :paused, :held]
  @terminal_statuses [:completed, :aborted, :faulted]

  @spec build(State.t(), keyword()) :: map()
  def build(%State{} = state, opts \\ []) do
    topology_scope = Keyword.get(opts, :topology_scope, :all)
    run = State.sequence_run(state)
    pending_intent = State.pending_intent(state)
    runtime = State.runtime(state)
    control_mode = State.control_mode(state)

    %{
      topology_scope: topology_scope,
      scope_matches_runtime?: scope_matches_runtime?(state, topology_scope),
      control_mode: control_mode,
      owner: State.owner(state),
      owner_kind: owner_kind(state),
      selected_procedure_id: State.selected_procedure_id(state),
      run_policy: run.policy,
      runtime_observed: runtime.observed,
      runtime_trust_state: runtime.trust_state,
      runtime_blockers: runtime_blockers(runtime.invalidation_reasons),
      active_run: active_run(run),
      terminal_result: terminal_result(run),
      pending_intent: %{
        pause_requested?: pending_intent.pause.requested?,
        abort_requested?: pending_intent.abort.requested?,
        takeover_requested?: pending_intent.takeover.requested?
      },
      actions: %{
        arm_auto?: control_mode == :manual and State.owner(state) == :manual_operator,
        switch_to_manual?: control_mode == :auto and State.owner(state) == :manual_operator,
        set_cycle_policy?: set_policy_available?(state, :cycle),
        set_once_policy?: set_policy_available?(state, :once),
        run_selected?: run_selected?(state, topology_scope),
        pause?: run.status == :running and State.owner(state) != :manual_operator,
        resume?:
          resumable_run?(run, runtime.invalidation_reasons, pending_intent.takeover.requested?),
        abort?: run.status in [:starting, :running, :paused],
        acknowledge?: acknowledgeable_run?(run),
        clear_result?: clearable_run_result?(run),
        request_manual_takeover?: manual_takeover_available?(state)
      }
    }
  end

  defp owner_kind(%State{} = state) do
    cond do
      State.pending_intent(state).takeover.requested? -> :manual_takeover_pending
      match?({:sequence_run, _run_id}, State.owner(state)) -> :procedure
      true -> :manual_operator
    end
  end

  defp active_run(%SequenceRunState{status: status} = run) when status in @active_statuses do
    %{
      status: status,
      sequence_id: run.sequence_id,
      run_id: run.run_id,
      current_procedure: run.current_procedure,
      current_step_label: run.current_step_label,
      resumable?: run.resumable?,
      resume_from_boundary: run.resume_from_boundary,
      resume_blockers: run.resume_blockers,
      last_error: run.last_error
    }
  end

  defp active_run(_run), do: nil

  defp terminal_result(%SequenceRunState{status: status} = run)
       when status in @terminal_statuses do
    %{
      status: status,
      sequence_id: run.sequence_id,
      run_id: run.run_id,
      last_error: run.last_error
    }
  end

  defp terminal_result(_run), do: nil

  defp runtime_blockers(reasons) when is_list(reasons) do
    Enum.map(reasons, &humanize_runtime_reason/1)
  end

  defp run_selected?(%State{} = state, topology_scope) do
    case selected_procedure_entry(state, topology_scope) do
      %{startable?: true} -> true
      _other -> false
    end
  end

  defp resumable_run?(
         %SequenceRunState{status: status, resumable?: true, resume_blockers: blockers},
         reasons,
         false
       )
       when status in [:paused, :held] do
    blockers in [[], nil] and reasons in [[], nil]
  end

  defp resumable_run?(_run, _reasons, _takeover_requested?), do: false

  defp acknowledgeable_run?(%SequenceRunState{status: status}), do: status in [:held, :faulted]

  defp clearable_run_result?(%SequenceRunState{status: status}),
    do: status in [:completed, :aborted]

  defp set_policy_available?(%State{} = state, policy) when policy in [:once, :cycle] do
    run = State.sequence_run(state)

    State.owner(state) == :manual_operator and
      run.status == :idle and
      run.policy != policy
  end

  defp manual_takeover_available?(%State{} = state) do
    control_mode = State.control_mode(state)
    pending_takeover? = State.pending_intent(state).takeover.requested?
    run_status = State.sequence_run(state).status

    control_mode == :auto and not pending_takeover? and run_status in @active_statuses
  end

  defp scope_matches_runtime?(_state, :all), do: true
  defp scope_matches_runtime?(_state, nil), do: true

  defp scope_matches_runtime?(%State{} = state, topology_scope) when is_binary(topology_scope) do
    case State.runtime(state).active_topology_module do
      module when is_atom(module) and not is_nil(module) ->
        Topology.scope_name(module) == topology_scope

      _other ->
        false
    end
  end

  defp humanize_runtime_reason(:workspace_changed),
    do: "Workspace changed after runtime deployment."

  defp humanize_runtime_reason(:runtime_not_running), do: "Runtime is not running."

  defp humanize_runtime_reason(:topology_generation_changed),
    do: "Topology generation changed."

  defp humanize_runtime_reason(:missing_realized_workspace_hash),
    do: "Runtime realization fingerprint is missing."

  defp humanize_runtime_reason(:missing_topology_generation),
    do: "Runtime topology generation is missing."

  defp humanize_runtime_reason({:runtime_failed, reason}),
    do: "Runtime failed: #{inspect(reason)}"

  defp humanize_runtime_reason({:sequence_runner_exited, reason}),
    do: "Sequence runner exited: #{inspect(reason)}"

  defp humanize_runtime_reason(other), do: inspect(other)

  defp selected_procedure_entry(%State{} = state, topology_scope) do
    state
    |> OperatorProcedureCatalog.build(topology_scope: topology_scope)
    |> Enum.find(& &1.selected?)
  end
end
