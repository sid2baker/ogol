defmodule Ogol.Session.OperatorProcedureCatalog do
  @moduledoc false

  alias Ogol.Sequence.Model
  alias Ogol.Session.{ArtifactRuntime, RuntimeState, SequenceRunState, State, Workspace}
  alias Ogol.Topology

  @type reason_code ::
          :runtime_not_running
          | :missing_active_topology
          | :not_compiled
          | :runtime_artifact_blocked
          | :topology_mismatch
          | :runtime_not_trusted
          | :terminal_result_pending
          | :auto_mode_required
          | :manual_takeover_pending
          | :procedure_active
          | :other_procedure_active

  @type entry :: %{
          sequence_id: String.t(),
          label: String.t(),
          summary: String.t() | nil,
          eligible?: boolean(),
          eligibility_reason_code: reason_code() | nil,
          eligibility_reason_text: String.t() | nil,
          startable?: boolean(),
          blocked_reason_code: reason_code() | nil,
          blocked_reason_text: String.t() | nil,
          selected?: boolean(),
          active?: boolean(),
          group: String.t() | nil
        }

  @spec build(State.t(), keyword()) :: [entry()]
  def build(%State{} = state, opts \\ []) do
    topology_scope = Keyword.get(opts, :topology_scope)
    selected_procedure_id = State.selected_procedure_id(state)
    active_sequence_id = active_sequence_id(state)

    state
    |> State.list_entries(:sequence)
    |> Enum.filter(&matches_topology_scope?(state, &1, topology_scope))
    |> Enum.map(fn %Workspace.SourceDraft{} = draft ->
      eligibility_reason_code = eligibility_reason_code(state, draft.id)
      blocked_reason_code = blocked_reason_code(state, draft.id, eligibility_reason_code)

      %{
        sequence_id: draft.id,
        label: procedure_label(state, draft),
        summary: procedure_summary(state, draft),
        eligible?: is_nil(eligibility_reason_code),
        eligibility_reason_code: eligibility_reason_code,
        eligibility_reason_text: reason_text(eligibility_reason_code),
        startable?: is_nil(eligibility_reason_code) and is_nil(blocked_reason_code),
        blocked_reason_code: blocked_reason_code,
        blocked_reason_text: reason_text(blocked_reason_code),
        selected?: selected_procedure_id == draft.id,
        active?: active_sequence_id == draft.id,
        group: nil
      }
    end)
  end

  defp matches_topology_scope?(_state, _draft, nil), do: true
  defp matches_topology_scope?(_state, _draft, :all), do: true

  defp matches_topology_scope?(%State{} = state, %Workspace.SourceDraft{} = draft, topology_scope)
       when is_binary(topology_scope) do
    case sequence_topology_scope(state, draft) do
      nil -> false
      ^topology_scope -> true
      _other -> false
    end
  end

  defp eligibility_reason_code(%State{} = state, sequence_id) when is_binary(sequence_id) do
    runtime = State.runtime(state)
    runtime_status = State.runtime_artifact_status(state, :sequence, sequence_id)

    case {runtime, State.runtime_current(state, :sequence, sequence_id), runtime_status} do
      {%RuntimeState{observed: observed}, _module, _runtime_status}
      when observed not in [{:running, :simulation}, {:running, :live}] ->
        :runtime_not_running

      {%RuntimeState{active_topology_module: nil}, _module, _runtime_status} ->
        :missing_active_topology

      {%RuntimeState{active_topology_module: active_topology_module}, module, _runtime_status}
      when is_atom(module) and not is_nil(module) and is_atom(active_topology_module) and
             not is_nil(active_topology_module) ->
        if sequence_topology(module) == active_topology_module do
          nil
        else
          :topology_mismatch
        end

      {_runtime, _module, %ArtifactRuntime{blocked_reason: reason}} when not is_nil(reason) ->
        :runtime_artifact_blocked

      _other ->
        :not_compiled
    end
  end

  defp blocked_reason_code(_state, _sequence_id, reason_code) when not is_nil(reason_code),
    do: nil

  defp blocked_reason_code(%State{} = state, sequence_id, nil) when is_binary(sequence_id) do
    cond do
      terminal_result_pending?(state) ->
        :terminal_result_pending

      takeover_pending?(state) ->
        :manual_takeover_pending

      active_sequence_id(state) == sequence_id ->
        :procedure_active

      active_sequence?(state) ->
        :other_procedure_active

      State.control_mode(state) != :auto ->
        :auto_mode_required

      State.runtime(state).trust_state != :trusted ->
        :runtime_not_trusted

      true ->
        nil
    end
  end

  defp terminal_result_pending?(%State{} = state) do
    match?(
      %SequenceRunState{status: status} when status in [:completed, :aborted, :faulted],
      State.sequence_run(state)
    )
  end

  defp takeover_pending?(%State{} = state) do
    case State.pending_intent(state) do
      %{takeover: %{requested?: true, fulfilled?: false}} -> true
      _other -> false
    end
  end

  defp active_sequence?(%State{} = state) do
    active_sequence_id(state) != nil
  end

  defp active_sequence_id(%State{} = state) do
    case {State.owner(state), State.sequence_run(state)} do
      {{:sequence_run, _run_id}, %SequenceRunState{status: status, sequence_id: sequence_id}}
      when status in [:starting, :running, :paused, :held] and is_binary(sequence_id) ->
        sequence_id

      _other ->
        nil
    end
  end

  defp sequence_topology(module) when is_atom(module) and not is_nil(module) do
    case sequence_model(module) do
      %Model{sequence: %Model.SequenceDefinition{topology: topology}} when is_atom(topology) ->
        topology

      _other ->
        nil
    end
  end

  defp procedure_label(%State{} = state, %Workspace.SourceDraft{id: id, model: draft_model}) do
    case current_sequence_model(state, id) do
      %Model{sequence: %Model.SequenceDefinition{name: name}} when is_atom(name) ->
        humanize_identifier(name)

      _other ->
        (draft_model || %{})
        |> Map.get(:name)
        |> case do
          name when is_atom(name) -> humanize_identifier(name)
          name when is_binary(name) -> humanize_identifier(name)
          _other -> humanize_identifier(id)
        end
    end
  end

  defp procedure_summary(%State{} = state, %Workspace.SourceDraft{id: id, model: draft_model}) do
    case current_sequence_model(state, id) do
      %Model{sequence: %Model.SequenceDefinition{meaning: meaning}}
      when is_binary(meaning) and byte_size(meaning) > 0 ->
        meaning

      _other ->
        case Map.get(draft_model || %{}, :meaning) do
          meaning when is_binary(meaning) and byte_size(meaning) > 0 -> meaning
          _other -> nil
        end
    end
  end

  defp current_sequence_model(%State{} = state, sequence_id) when is_binary(sequence_id) do
    case State.runtime_current(state, :sequence, sequence_id) do
      module when is_atom(module) and not is_nil(module) -> sequence_model(module)
      _other -> nil
    end
  end

  defp sequence_model(module) when is_atom(module) and not is_nil(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        nil

      not function_exported?(module, :__ogol_sequence__, 0) ->
        nil

      true ->
        module.__ogol_sequence__()
    end
  end

  defp sequence_topology_scope(%State{} = state, %Workspace.SourceDraft{
         id: id,
         model: draft_model
       }) do
    case current_sequence_model(state, id) do
      %Model{sequence: %Model.SequenceDefinition{topology: topology}} when is_atom(topology) ->
        Topology.scope_name(topology)

      _other ->
        draft_model_topology_scope(draft_model)
    end
  end

  defp draft_model_topology_scope(%{topology_module_name: module_name})
       when is_binary(module_name) do
    Topology.scope_name(module_name)
  end

  defp draft_model_topology_scope(%{topology: topology}) when is_atom(topology) do
    Topology.scope_name(topology)
  end

  defp draft_model_topology_scope(%Model{sequence: %Model.SequenceDefinition{topology: topology}})
       when is_atom(topology) do
    Topology.scope_name(topology)
  end

  defp draft_model_topology_scope(_draft_model), do: nil

  defp reason_text(nil), do: nil
  defp reason_text(:runtime_not_running), do: "Runtime is not running."

  defp reason_text(:missing_active_topology),
    do: "The active cell topology is not available."

  defp reason_text(:not_compiled), do: "Procedure is not compiled into the active runtime."

  defp reason_text(:runtime_artifact_blocked),
    do: "Procedure is blocked in the active runtime."

  defp reason_text(:topology_mismatch),
    do: "Procedure does not belong to the active cell topology."

  defp reason_text(:runtime_not_trusted),
    do: "Restore runtime trust before starting a procedure."

  defp reason_text(:terminal_result_pending),
    do: "Clear or acknowledge the last procedure result before starting another procedure."

  defp reason_text(:auto_mode_required),
    do: "Switch the cell to Auto before starting a procedure."

  defp reason_text(:manual_takeover_pending), do: "Manual takeover is pending."
  defp reason_text(:procedure_active), do: "This procedure is already active."
  defp reason_text(:other_procedure_active), do: "Another procedure currently owns the cell."

  defp humanize_identifier(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> humanize_identifier()
  end

  defp humanize_identifier(value) when is_binary(value) do
    value
    |> String.split(["_", "-"], trim: true)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
