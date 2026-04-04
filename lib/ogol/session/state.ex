defmodule Ogol.Session.State do
  @moduledoc false

  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Studio.Build
  alias Ogol.Session.{ArtifactRuntime, RuntimeState, SequenceRunState, Workspace}

  @type control_mode :: :manual | :auto
  @type owner :: :manual_operator | {:sequence_run, String.t()}
  @type pending_intent_entry :: %{
          requested?: boolean(),
          requested_by: term() | nil,
          requested_at: DateTime.t() | nil,
          admitted?: boolean(),
          admitted_at: DateTime.t() | nil,
          fulfilled?: boolean(),
          fulfilled_at: DateTime.t() | nil
        }
  @type pending_intent :: %{
          pause: pending_intent_entry(),
          abort: pending_intent_entry()
        }

  @type t :: %__MODULE__{
          workspace: Workspace.t(),
          control_mode: control_mode(),
          owner: owner(),
          pending_intent: pending_intent(),
          runtime: RuntimeState.t(),
          artifact_runtime: %{optional(ArtifactRuntime.key()) => ArtifactRuntime.t()},
          sequence_run: SequenceRunState.t()
        }

  @type kind :: Workspace.kind()
  @type runtime_realization :: RuntimeState.realization()
  @type runtime_operation ::
          {:compile_artifact, :hardware | :machine | :topology | :sequence, String.t()}
          | {:set_control_mode, control_mode()}
          | {:set_sequence_run_policy, SequenceRunState.run_policy()}
          | {:set_desired_runtime, runtime_realization()}
          | {:start_sequence_run, String.t()}
          | :acknowledge_sequence_run
          | :clear_sequence_run_result
          | :pause_sequence_run
          | :resume_sequence_run
          | :cancel_sequence_run
          | :reset_runtime_state
          | {:sync_auto_control, control_mode(), owner()}
          | {:replace_artifact_runtime, [map()]}
          | {:runtime_started, runtime_realization(), map()}
          | {:runtime_stopped, map()}
          | {:runtime_failed, runtime_realization(), term()}
          | {:sequence_pause_requested, map()}
          | {:sequence_abort_requested, map()}
          | {:sequence_run_admitted, map()}
          | {:sequence_run_started, map()}
          | {:sequence_run_advanced, map()}
          | {:sequence_run_paused, map()}
          | {:sequence_run_resumed, map()}
          | {:sequence_run_held, map()}
          | {:sequence_run_completed, map()}
          | {:sequence_run_failed, map()}
          | {:sequence_run_aborted, map()}

  @type operation :: Workspace.operation() | runtime_operation()

  @type action ::
          {:compile_artifact, :hardware | :machine | :topology | :sequence, String.t(),
           Workspace.t()}
          | {:delete_artifact, :machine | :topology | :sequence | :hardware | :simulator_config,
             String.t()}
          | {:set_control_mode, control_mode()}
          | {:set_sequence_run_policy, SequenceRunState.run_policy()}
          | {:reconcile_runtime, Workspace.t(), RuntimeState.t()}
          | {:start_sequence_run, String.t(), module(), RuntimeState.t(),
             SequenceRunState.run_policy()}
          | :acknowledge_sequence_run
          | :pause_sequence_run
          | :resume_sequence_run
          | {:hold_sequence_run, [term()]}
          | :cancel_sequence_run

  @runtime_artifact_kinds [:machine, :topology, :sequence, :hardware]
  @compilable_kinds [:hardware, :machine, :topology, :sequence]

  defstruct workspace: nil,
            control_mode: :manual,
            owner: :manual_operator,
            pending_intent: nil,
            runtime: %RuntimeState{},
            artifact_runtime: %{},
            sequence_run: %SequenceRunState{}

  def new,
    do: %__MODULE__{
      workspace: Workspace.new(),
      control_mode: :manual,
      owner: :manual_operator,
      pending_intent: default_pending_intent(),
      runtime: %RuntimeState{},
      artifact_runtime: %{},
      sequence_run: %SequenceRunState{}
    }

  def workspace(%__MODULE__{workspace: %Workspace{} = workspace}), do: workspace
  def control_mode(%__MODULE__{control_mode: control_mode}), do: control_mode
  def owner(%__MODULE__{owner: owner}), do: owner
  def pending_intent(%__MODULE__{pending_intent: pending_intent}), do: pending_intent
  def runtime(%__MODULE__{runtime: %RuntimeState{} = runtime}), do: runtime
  def artifact_runtime(%__MODULE__{artifact_runtime: artifact_runtime}), do: artifact_runtime

  def sequence_run(%__MODULE__{sequence_run: %SequenceRunState{} = sequence_run}),
    do: sequence_run

  @spec runtime_realized?(t()) :: boolean()
  def runtime_realized?(%__MODULE__{} = state) do
    case runtime(state) do
      %RuntimeState{observed: :stopped, realized_workspace_hash: nil} ->
        true

      %RuntimeState{observed: {:running, _mode}, realized_workspace_hash: realized_hash}
      when is_binary(realized_hash) ->
        realized_hash == workspace_hash(workspace(state))

      _other ->
        false
    end
  end

  @spec runtime_dirty?(t()) :: boolean()
  def runtime_dirty?(%__MODULE__{} = state) do
    case runtime(state) do
      %RuntimeState{observed: {:running, _mode}, realized_workspace_hash: realized_hash}
      when is_binary(realized_hash) ->
        realized_hash != workspace_hash(workspace(state))

      %RuntimeState{observed: {:running, _mode}} ->
        true

      _other ->
        false
    end
  end

  @spec workspace_hash(Workspace.t()) :: String.t()
  def workspace_hash(%Workspace{} = workspace) do
    workspace
    |> workspace_hash_payload()
    |> :erlang.term_to_binary()
    |> Build.digest()
  end

  @spec apply_operation(t(), operation()) ::
          {:ok, t(), term(), [operation()], [action()]} | :error
  def apply_operation(data, operation)

  def apply_operation(%__MODULE__{} = data, {:compile_artifact, kind, id})
      when kind in @compilable_kinds and is_binary(id) do
    with {:ok, _entry} <- fetch_entry(data, kind, id) do
      data
      |> with_actions()
      |> add_action({:compile_artifact, kind, id, workspace(data)})
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def apply_operation(%__MODULE__{} = data, {:set_control_mode, control_mode} = operation)
      when control_mode in [:manual, :auto] do
    with :ok <- validate_control_mode_change(data, control_mode) do
      data
      |> with_actions(:ok, [operation])
      |> add_action({:set_control_mode, control_mode})
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def apply_operation(%__MODULE__{} = data, {:set_sequence_run_policy, policy} = operation)
      when policy in [:once, :cycle] do
    case {owner(data), sequence_run(data)} do
      {:manual_operator, %SequenceRunState{status: status} = run}
      when status in [:idle, :completed, :aborted, :faulted] ->
        data
        |> with_actions(:ok, [operation])
        |> put_sequence_run(%SequenceRunState{run | policy: policy, cycle_count: 0})
        |> wrap_ok()

      _other ->
        :error
    end
  end

  def apply_operation(%__MODULE__{} = data, {:set_desired_runtime, desired} = operation)
      when desired in [:stopped, {:running, :simulation}, {:running, :live}] do
    next_runtime =
      data
      |> runtime()
      |> Map.put(:desired, desired)
      |> Map.put(:status, :reconciling)
      |> Map.put(:last_error, nil)

    data
    |> with_actions(:ok, [operation])
    |> put_runtime(next_runtime)
    |> refresh_runtime_trust()
    |> maybe_reset_active_sequence_for_runtime_reconcile()
    |> add_action({:reconcile_runtime, workspace(data), next_runtime})
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:start_sequence_run, sequence_id} = operation)
      when is_binary(sequence_id) do
    with {:ok, _entry} <- fetch_entry(data, :sequence, sequence_id),
         :auto <- control_mode(data),
         :manual_operator <- owner(data),
         %SequenceRunState{status: status} <- sequence_run(data),
         false <- status in [:starting, :running],
         {:ok, %RuntimeState{} = current_runtime} <- running_runtime(data),
         true <- runtime_realized?(data),
         module when is_atom(module) <- runtime_current(data, :sequence, sequence_id) do
      policy = sequence_run(data).policy

      data
      |> with_actions(:ok, [operation])
      |> add_action({:start_sequence_run, sequence_id, module, current_runtime, policy})
      |> wrap_ok()
    else
      _other ->
        :error
    end
  end

  def apply_operation(%__MODULE__{} = data, :acknowledge_sequence_run = operation) do
    case {owner(data), sequence_run(data)} do
      {{:sequence_run, _run_id}, %SequenceRunState{status: :held}} ->
        data
        |> with_actions()
        |> add_action(:acknowledge_sequence_run)
        |> wrap_ok()

      {:manual_operator, %SequenceRunState{status: status} = run}
      when status in [:completed, :aborted, :faulted] ->
        data
        |> with_actions(:ok, [operation])
        |> put_pending_intent(default_pending_intent())
        |> put_sequence_run(cleared_sequence_run(run))
        |> wrap_ok()

      _other ->
        :error
    end
  end

  def apply_operation(%__MODULE__{} = data, :clear_sequence_run_result = operation) do
    case sequence_run(data) do
      %SequenceRunState{status: status} = run
      when status in [:held, :completed, :aborted, :faulted] ->
        data
        |> with_actions(:ok, [operation])
        |> put_pending_intent(default_pending_intent())
        |> put_sequence_run(cleared_sequence_run(run))
        |> wrap_ok()

      _other ->
        :error
    end
  end

  def apply_operation(%__MODULE__{} = data, :pause_sequence_run = operation) do
    case {owner(data), sequence_run(data), pending_intent(data)} do
      {{:sequence_run, _run_id}, %SequenceRunState{status: :running},
       %{pause: %{requested?: false}}} ->
        data
        |> with_actions(:ok, [operation])
        |> add_action(:pause_sequence_run)
        |> wrap_ok()

      _other ->
        :error
    end
  end

  def apply_operation(%__MODULE__{} = data, :resume_sequence_run = operation) do
    case {owner(data), sequence_run(data), runtime(data)} do
      {{:sequence_run, _run_id},
       %SequenceRunState{status: status, resumable?: true, resume_blockers: blockers},
       %RuntimeState{trust_state: :trusted, observed: observed}}
      when status in [:paused, :held] and blockers in [[], nil] and
             observed in [{:running, :simulation}, {:running, :live}] ->
        data
        |> with_actions(:ok, [operation])
        |> add_action(:resume_sequence_run)
        |> wrap_ok()

      _other ->
        :error
    end
  end

  def apply_operation(%__MODULE__{} = data, :cancel_sequence_run = operation) do
    case sequence_run(data) do
      %SequenceRunState{status: status} when status in [:starting, :running, :paused, :held] ->
        data
        |> with_actions(:ok, [operation])
        |> add_action(:cancel_sequence_run)
        |> wrap_ok()

      _other ->
        :error
    end
  end

  def apply_operation(%__MODULE__{} = data, :reset_runtime_state = operation) do
    data
    |> with_actions(:ok, [operation])
    |> put_control_mode(:manual)
    |> put_owner(:manual_operator)
    |> put_pending_intent(default_pending_intent())
    |> put_runtime(%RuntimeState{})
    |> put_artifact_runtime(%{})
    |> put_sequence_run(%SequenceRunState{})
    |> wrap_ok()
  end

  def apply_operation(
        %__MODULE__{} = data,
        {:sync_auto_control, control_mode, owner} = operation
      )
      when control_mode in [:manual, :auto] do
    next_owner = normalize_owner(control_mode, owner)

    data
    |> with_actions(:ok, [operation])
    |> put_control_mode(control_mode)
    |> put_owner(next_owner)
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:replace_artifact_runtime, statuses} = operation)
      when is_list(statuses) do
    data
    |> with_actions(:ok, [operation])
    |> put_artifact_runtime(normalize_artifact_runtime(statuses))
    |> wrap_ok()
  end

  def apply_operation(
        %__MODULE__{} = data,
        {:runtime_started, realization, details} = operation
      )
      when realization in [{:running, :simulation}, {:running, :live}] and is_map(details) do
    next_runtime =
      runtime(data)
      |> Map.put(:desired, realization)
      |> Map.put(:observed, realization)
      |> Map.put(:status, :running)
      |> Map.put(
        :topology_generation,
        Map.get(details, :topology_generation, Map.get(details, :deployment_id))
      )
      |> Map.put(:deployment_id, Map.get(details, :deployment_id))
      |> Map.put(:active_topology_module, Map.get(details, :active_topology_module))
      |> Map.put(
        :active_adapters,
        normalize_active_adapters(Map.get(details, :active_adapters, []))
      )
      |> Map.put(:realized_workspace_hash, Map.get(details, :realized_workspace_hash))
      |> Map.put(:last_error, nil)

    data
    |> with_actions(:ok, [operation])
    |> put_runtime(next_runtime)
    |> maybe_preserve_sequence_for_runtime_start()
    |> refresh_runtime_trust()
    |> sync_sequence_resumability_with_runtime_trust()
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:runtime_stopped, details} = operation)
      when is_map(details) do
    next_runtime =
      runtime(data)
      |> Map.put(:observed, :stopped)
      |> Map.put(:status, :idle)
      |> Map.put(:topology_generation, nil)
      |> Map.put(:deployment_id, nil)
      |> Map.put(:active_topology_module, nil)
      |> Map.put(:active_adapters, [])
      |> Map.put(:realized_workspace_hash, Map.get(details, :realized_workspace_hash))
      |> Map.put(:last_error, nil)

    data
    |> with_actions(:ok, [operation])
    |> put_runtime(next_runtime)
    |> put_pending_intent(default_pending_intent())
    |> maybe_preserve_active_sequence({:runtime_stopped, [:runtime_not_running]})
    |> refresh_runtime_trust()
    |> sync_sequence_resumability_with_runtime_trust()
    |> wrap_ok()
  end

  def apply_operation(
        %__MODULE__{} = data,
        {:runtime_failed, desired, reason} = operation
      )
      when desired in [:stopped, {:running, :simulation}, {:running, :live}] do
    next_runtime =
      runtime(data)
      |> Map.put(:desired, desired)
      |> Map.put(:observed, :stopped)
      |> Map.put(:status, :failed)
      |> Map.put(:topology_generation, nil)
      |> Map.put(:deployment_id, nil)
      |> Map.put(:active_topology_module, nil)
      |> Map.put(:active_adapters, [])
      |> Map.put(:realized_workspace_hash, nil)
      |> Map.put(:last_error, reason)

    data
    |> with_actions(:ok, [operation])
    |> put_runtime(next_runtime)
    |> put_pending_intent(default_pending_intent())
    |> maybe_preserve_active_sequence({:runtime_failed, [{:runtime_failed, reason}]})
    |> refresh_runtime_trust()
    |> sync_sequence_resumability_with_runtime_trust()
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_abort_requested, details} = operation)
      when is_map(details) do
    if sequence_abort_applicable?(data, details) do
      data
      |> with_actions(:ok, [operation])
      |> put_pending_intent(put_abort_intent(pending_intent(data), details))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_pause_requested, details} = operation)
      when is_map(details) do
    if sequence_pause_applicable?(data, details) do
      data
      |> with_actions(:ok, [operation])
      |> put_pending_intent(put_pause_intent(pending_intent(data), details))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_admitted, snapshot} = operation)
      when is_map(snapshot) do
    data
    |> with_actions(:ok, [operation])
    |> put_pending_intent(default_pending_intent())
    |> put_sequence_run(SequenceRunState.from_snapshot(:starting, snapshot))
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_started, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
      |> put_sequence_run(SequenceRunState.from_snapshot(:running, snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_advanced, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
      |> put_sequence_run(SequenceRunState.from_snapshot(:running, snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_paused, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
      |> put_pending_intent(fulfill_pause_intent(pending_intent(data)))
      |> put_sequence_run(SequenceRunState.from_snapshot(:paused, snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_resumed, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
      |> put_pending_intent(clear_pause_intent(pending_intent(data)))
      |> put_sequence_run(SequenceRunState.from_snapshot(:running, snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_held, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      next_snapshot = merge_held_snapshot(sequence_run(data), snapshot)

      data
      |> with_actions(:ok, [operation])
      |> put_sequence_run(SequenceRunState.from_snapshot(:held, next_snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_completed, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
      |> put_pending_intent(default_pending_intent())
      |> put_sequence_run(SequenceRunState.from_snapshot(:completed, snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_failed, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
      |> put_pending_intent(default_pending_intent())
      |> put_sequence_run(SequenceRunState.from_snapshot(:faulted, snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_aborted, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
      |> put_pending_intent(default_pending_intent())
      |> put_sequence_run(SequenceRunState.from_snapshot(:aborted, snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:delete_entry, kind, _id} = operation)
      when kind in @runtime_artifact_kinds do
    current_workspace = workspace(data)

    with {:ok, next_workspace, reply, operations} <-
           Workspace.apply_operation(current_workspace, operation) do
      data
      |> with_actions(reply, operations)
      |> put_workspace(next_workspace)
      |> add_delete_actions(current_workspace, kind)
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def apply_operation(%__MODULE__{} = data, {:replace_entries, kind, _drafts} = operation)
      when kind in @runtime_artifact_kinds do
    current_workspace = workspace(data)

    with {:ok, next_workspace, reply, operations} <-
           Workspace.apply_operation(current_workspace, operation) do
      data
      |> with_actions(reply, operations)
      |> put_workspace(next_workspace)
      |> add_delete_actions(current_workspace, kind)
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def apply_operation(%__MODULE__{} = data, {:reset_kind, kind} = operation)
      when kind in @runtime_artifact_kinds do
    current_workspace = workspace(data)

    with {:ok, next_workspace, reply, operations} <-
           Workspace.apply_operation(current_workspace, operation) do
      data
      |> with_actions(reply, operations)
      |> put_workspace(next_workspace)
      |> add_delete_actions(current_workspace, kind)
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def apply_operation(%__MODULE__{} = data, operation) do
    previous_runtime = runtime(data)

    with {:ok, next_workspace, reply, operations} <-
           Workspace.apply_operation(workspace(data), operation) do
      data
      |> with_actions(reply, operations)
      |> put_workspace(next_workspace)
      |> refresh_runtime_trust()
      |> sync_sequence_resumability_with_runtime_trust()
      |> maybe_hold_active_sequence(previous_runtime)
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def list_kind(%__MODULE__{workspace: %Workspace{} = workspace}, kind) when is_atom(kind),
    do: Workspace.list_kind(workspace, kind)

  def list_entries(%__MODULE__{workspace: %Workspace{} = workspace}, kind),
    do: Workspace.list_entries(workspace, kind)

  def fetch(%__MODULE__{workspace: %Workspace{} = workspace}, kind, id)
      when is_atom(kind) and is_binary(id),
      do: Workspace.fetch(workspace, kind, id)

  def hardware_model(%__MODULE__{workspace: %Workspace{} = workspace}, id)
      when is_binary(id) do
    Workspace.hardware_model(workspace, id)
  end

  def simulator_config_model(%__MODULE__{workspace: %Workspace{} = workspace}, id)
      when is_binary(id) do
    Workspace.simulator_config_model(workspace, id)
  end

  def loaded_inventory(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.loaded_inventory(workspace)
  end

  def machine_contract_descriptor(%__MODULE__{} = data, machine_id) when is_binary(machine_id) do
    case fetch(data, :machine, machine_id) do
      %{source: source} when is_binary(source) ->
        case MachineSource.contract_projection_from_source(source) do
          {:ok, descriptor} -> descriptor
          {:error, _diagnostics} -> nil
        end

      _other ->
        nil
    end
  end

  def runtime_artifact_status(%__MODULE__{} = data, kind, id)
      when kind in @runtime_artifact_kinds and is_binary(id) do
    artifact_runtime(data)
    |> Map.get({kind, id})
  end

  def runtime_current(%__MODULE__{} = data, kind, id)
      when kind in @runtime_artifact_kinds and is_binary(id) do
    case runtime_artifact_status(data, kind, id) do
      %ArtifactRuntime{module: module} when is_atom(module) -> module
      _other -> nil
    end
  end

  def loaded_revision(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.loaded_revision(workspace)
  end

  def workspace_session(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.workspace_session(workspace)
  end

  defp running_runtime(%__MODULE__{} = data) do
    case runtime(data) do
      %RuntimeState{observed: observed} = current_runtime
      when observed in [{:running, :simulation}, {:running, :live}] ->
        {:ok, current_runtime}

      _other ->
        :error
    end
  end

  defp sequence_feedback_applicable?(%__MODULE__{} = data, snapshot) when is_map(snapshot) do
    case {Map.get(snapshot, :run_id), sequence_run(data), runtime(data)} do
      {run_id, %SequenceRunState{run_id: run_id}, _runtime} when is_binary(run_id) ->
        true

      {_, _sequence_run, %RuntimeState{deployment_id: deployment_id}}
      when is_binary(deployment_id) ->
        Map.get(snapshot, :deployment_id) == deployment_id

      _other ->
        false
    end
  end

  defp merge_held_snapshot(
         %SequenceRunState{status: :held, last_error: {:trust_invalidated, current_reasons}} =
           current_run,
         snapshot
       )
       when is_list(current_reasons) do
    incoming_reasons = extract_trust_invalidation_reasons(snapshot)

    if hold_reason_priority(incoming_reasons) >= hold_reason_priority(current_reasons) do
      snapshot
    else
      snapshot
      |> Map.put(:last_error, {:trust_invalidated, current_reasons})
      |> preserve_fault_classification(current_run)
    end
  end

  defp merge_held_snapshot(_current_run, snapshot), do: snapshot

  defp preserve_fault_classification(snapshot, %SequenceRunState{} = run) when is_map(snapshot) do
    snapshot
    |> Map.put(:fault_source, run.fault_source)
    |> Map.put(:fault_recoverability, run.fault_recoverability)
    |> Map.put(:fault_scope, run.fault_scope)
  end

  defp extract_trust_invalidation_reasons(snapshot) when is_map(snapshot) do
    case Map.get(snapshot, :last_error) do
      {:trust_invalidated, reasons} when is_list(reasons) -> reasons
      _other -> []
    end
  end

  defp hold_reason_priority(reasons) when is_list(reasons) do
    if Enum.empty?(reasons) or Enum.all?(reasons, &match?({:sequence_runner_exited, _}, &1)) do
      0
    else
      1
    end
  end

  defp fetch_entry(%__MODULE__{} = data, kind, id) do
    case fetch(data, kind, id) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  defp put_workspace({%__MODULE__{} = data, reply, operations, actions}, %Workspace{} = workspace) do
    {%__MODULE__{data | workspace: workspace}, reply, operations, actions}
  end

  defp put_control_mode(
         {%__MODULE__{} = data, reply, operations, actions},
         control_mode
       )
       when control_mode in [:manual, :auto] do
    {%__MODULE__{data | control_mode: control_mode}, reply, operations, actions}
  end

  defp put_owner({%__MODULE__{} = data, reply, operations, actions}, :manual_operator) do
    {%__MODULE__{data | owner: :manual_operator}, reply, operations, actions}
  end

  defp put_owner(
         {%__MODULE__{} = data, reply, operations, actions},
         {:sequence_run, run_id} = owner
       )
       when is_binary(run_id) do
    {%__MODULE__{data | owner: owner}, reply, operations, actions}
  end

  defp put_pending_intent(
         {%__MODULE__{} = data, reply, operations, actions},
         pending_intent
       )
       when is_map(pending_intent) do
    {%__MODULE__{data | pending_intent: pending_intent}, reply, operations, actions}
  end

  defp put_runtime(
         {%__MODULE__{} = data, reply, operations, actions},
         %RuntimeState{} = runtime
       ) do
    {%__MODULE__{data | runtime: runtime}, reply, operations, actions}
  end

  defp refresh_runtime_trust({%__MODULE__{} = data, reply, operations, actions}) do
    runtime = runtime(data)

    {trust_state, invalidation_reasons} =
      infer_runtime_trust(runtime, workspace(data), sequence_run(data), owner(data))

    {%__MODULE__{
       data
       | runtime: %RuntimeState{
           runtime
           | trust_state: trust_state,
             invalidation_reasons: invalidation_reasons
         }
     }, reply, operations, actions}
  end

  defp sync_sequence_resumability_with_runtime_trust(
         {%__MODULE__{} = data, _reply, _operations, _actions} = data_actions
       ) do
    case {owner(data), sequence_run(data),
          runtime_resume_blockers(runtime(data).invalidation_reasons)} do
      {{:sequence_run, _run_id}, %SequenceRunState{status: status} = run, blockers}
      when status in [:paused, :held] and blockers != [] ->
        {fault_recoverability, fault_scope} =
          trust_fault_classification(runtime(data).invalidation_reasons)

        updated_run = %SequenceRunState{
          run
          | resumable?: false,
            resume_blockers: Enum.uniq(List.wrap(run.resume_blockers) ++ blockers),
            fault_source: :external_runtime,
            fault_recoverability: fault_recoverability,
            fault_scope: fault_scope,
            last_error: {:trust_invalidated, runtime(data).invalidation_reasons}
        }

        put_sequence_run(data_actions, updated_run)

      _other ->
        data_actions
    end
  end

  defp put_artifact_runtime(
         {%__MODULE__{} = data, reply, operations, actions},
         artifact_runtime
       )
       when is_map(artifact_runtime) do
    {%__MODULE__{data | artifact_runtime: artifact_runtime}, reply, operations, actions}
  end

  defp put_sequence_run(
         {%__MODULE__{} = data, reply, operations, actions},
         %SequenceRunState{} = sequence_run
       ) do
    {%__MODULE__{data | sequence_run: sequence_run}, reply, operations, actions}
  end

  defp maybe_preserve_active_sequence(
         {%__MODULE__{} = data, _reply, _operations, _actions} = data_actions,
         {_kind, reasons}
       )
       when is_list(reasons) do
    case {owner(data), sequence_run(data)} do
      {{:sequence_run, _run_id}, %SequenceRunState{status: status}}
      when status in [:starting, :running, :paused, :held] ->
        data_actions
        |> add_action_if_running(status, reasons)

      _other ->
        data_actions
        |> put_owner(:manual_operator)
        |> put_sequence_run(%SequenceRunState{})
    end
  end

  defp maybe_preserve_sequence_for_runtime_start(
         {%__MODULE__{} = data, _reply, _operations, _actions} = data_actions
       ) do
    case {owner(data), sequence_run(data)} do
      {{:sequence_run, _run_id}, %SequenceRunState{status: status}}
      when status in [:starting, :running, :paused, :held] ->
        data_actions

      _other ->
        data_actions
        |> put_owner(:manual_operator)
        |> put_pending_intent(default_pending_intent())
        |> put_sequence_run(%SequenceRunState{})
    end
  end

  defp maybe_reset_active_sequence_for_runtime_reconcile(
         {%__MODULE__{} = data, _reply, _operations, _actions} = data_actions
       ) do
    case {owner(data), sequence_run(data)} do
      {{:sequence_run, _run_id}, %SequenceRunState{status: status}}
      when status in [:starting, :running, :paused, :held] ->
        data_actions

      _other ->
        data_actions
        |> put_owner(:manual_operator)
        |> put_sequence_run(%SequenceRunState{})
    end
  end

  defp add_action_if_running(data_actions, status, reasons)
       when status in [:starting, :running, :paused, :held] do
    add_action(data_actions, {:hold_sequence_run, reasons})
  end

  defp add_delete_actions(
         {%__MODULE__{} = data, _reply, _operations, _actions} = data_actions,
         %Workspace{} = current_workspace,
         kind
       ) do
    next_workspace = workspace(data)

    current_workspace
    |> removed_entry_ids(next_workspace, kind)
    |> Enum.map(&{:delete_artifact, kind, &1})
    |> Enum.reduce(data_actions, fn action, acc -> add_action(acc, action) end)
  end

  defp maybe_hold_active_sequence(
         {%__MODULE__{} = data, _reply, _operations, _actions} = data_actions,
         %RuntimeState{} = previous_runtime
       ) do
    next_runtime = runtime(data)

    case {previous_runtime.trust_state, next_runtime.trust_state, owner(data), sequence_run(data)} do
      {previous, :invalidated, {:sequence_run, _run_id}, %SequenceRunState{status: status}}
      when previous != :invalidated and status in [:starting, :running, :paused] ->
        add_action(data_actions, {:hold_sequence_run, next_runtime.invalidation_reasons})

      _other ->
        data_actions
    end
  end

  defp with_actions(%__MODULE__{} = data, reply \\ :ok, operations \\ [])
       when is_list(operations) do
    {data, reply, operations, []}
  end

  defp add_action({data, reply, operations, actions}, action) do
    {data, reply, operations, actions ++ [action]}
  end

  defp wrap_ok({%__MODULE__{} = data, reply, operations, actions}) do
    {:ok, data, reply, operations, actions}
  end

  defp validate_control_mode_change(%__MODULE__{owner: :manual_operator}, :manual), do: :ok
  defp validate_control_mode_change(%__MODULE__{}, :auto), do: :ok
  defp validate_control_mode_change(%__MODULE__{}, :manual), do: :error

  defp normalize_owner(:manual, _owner), do: :manual_operator
  defp normalize_owner(:auto, :manual_operator), do: :manual_operator

  defp normalize_owner(:auto, {:sequence_run, run_id}) when is_binary(run_id),
    do: {:sequence_run, run_id}

  defp normalize_owner(:auto, _owner), do: :manual_operator

  defp default_pending_intent do
    %{pause: blank_intent_entry(), abort: blank_intent_entry()}
  end

  defp cleared_sequence_run(%SequenceRunState{policy: policy}) do
    %SequenceRunState{policy: policy}
  end

  defp infer_runtime_trust(
         %RuntimeState{
           observed: {:running, _mode},
           topology_generation: topology_generation
         },
         _workspace,
         %SequenceRunState{status: status, run_generation: run_generation},
         {:sequence_run, _run_id}
       )
       when status in [:starting, :running, :paused, :held] and is_binary(run_generation) and
              is_binary(topology_generation) and run_generation != topology_generation do
    {:invalidated, [:topology_generation_changed]}
  end

  defp infer_runtime_trust(
         %RuntimeState{observed: {:running, _mode}, realized_workspace_hash: realized_hash},
         %Workspace{} = workspace,
         _sequence_run,
         _owner
       )
       when is_binary(realized_hash) do
    case workspace_hash(workspace) do
      ^realized_hash -> {:trusted, []}
      _other -> {:invalidated, [:workspace_changed]}
    end
  end

  defp infer_runtime_trust(
         %RuntimeState{observed: {:running, _mode}, topology_generation: nil},
         _workspace,
         %SequenceRunState{status: status},
         {:sequence_run, _run_id}
       )
       when status in [:starting, :running, :paused, :held] do
    {:invalidated, [:missing_topology_generation]}
  end

  defp infer_runtime_trust(
         %RuntimeState{observed: {:running, _mode}},
         _workspace,
         _sequence_run,
         _owner
       ) do
    {:invalidated, [:missing_realized_workspace_hash]}
  end

  defp infer_runtime_trust(
         %RuntimeState{status: :failed, last_error: reason},
         _workspace,
         _sequence_run,
         _owner
       ) do
    {:invalidated, [{:runtime_failed, reason}]}
  end

  defp infer_runtime_trust(
         %RuntimeState{observed: :stopped},
         _workspace,
         %SequenceRunState{status: status},
         {:sequence_run, _run_id}
       )
       when status in [:starting, :running, :paused, :held] do
    {:invalidated, [:runtime_not_running]}
  end

  defp infer_runtime_trust(
         %RuntimeState{observed: :stopped, desired: :stopped},
         _workspace,
         _sequence_run,
         _owner
       ) do
    {:trusted, []}
  end

  defp infer_runtime_trust(%RuntimeState{observed: :stopped}, _workspace, _sequence_run, _owner) do
    {:invalidated, [:runtime_not_running]}
  end

  defp blank_intent_entry do
    %{
      requested?: false,
      requested_by: nil,
      requested_at: nil,
      admitted?: false,
      admitted_at: nil,
      fulfilled?: false,
      fulfilled_at: nil
    }
  end

  defp runtime_resume_blockers(reasons) when is_list(reasons) do
    Enum.reduce(reasons, [], fn
      :topology_generation_changed, acc -> [:topology_generation_changed | acc]
      :missing_topology_generation, acc -> [:missing_topology_generation | acc]
      :runtime_not_running, acc -> [:runtime_restart_requires_fresh_run | acc]
      {:runtime_failed, _reason}, acc -> [:runtime_restart_requires_fresh_run | acc]
      _other, acc -> acc
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp trust_fault_classification(reasons) when is_list(reasons) do
    recoverability =
      if runtime_resume_blockers(reasons) == [] do
        :operator_ack_required
      else
        :abort_required
      end

    {recoverability, :runtime_wide}
  end

  defp put_abort_intent(pending_intent, details)
       when is_map(pending_intent) and is_map(details) do
    Map.put(pending_intent, :abort, %{
      requested?: true,
      requested_by: Map.get(details, :requested_by),
      requested_at: Map.get(details, :requested_at),
      admitted?: true,
      admitted_at: Map.get(details, :admitted_at, Map.get(details, :requested_at)),
      fulfilled?: false,
      fulfilled_at: nil
    })
  end

  defp put_pause_intent(pending_intent, details)
       when is_map(pending_intent) and is_map(details) do
    Map.put(pending_intent, :pause, %{
      requested?: true,
      requested_by: Map.get(details, :requested_by),
      requested_at: Map.get(details, :requested_at),
      admitted?: true,
      admitted_at: Map.get(details, :admitted_at, Map.get(details, :requested_at)),
      fulfilled?: false,
      fulfilled_at: nil
    })
  end

  defp fulfill_pause_intent(pending_intent) when is_map(pending_intent) do
    Map.update!(pending_intent, :pause, fn pause ->
      %{pause | fulfilled?: true, fulfilled_at: DateTime.utc_now()}
    end)
  end

  defp clear_pause_intent(pending_intent) when is_map(pending_intent) do
    Map.put(pending_intent, :pause, blank_intent_entry())
  end

  defp sequence_pause_applicable?(%__MODULE__{} = data, details) when is_map(details) do
    case {owner(data), sequence_run(data)} do
      {{:sequence_run, run_id}, %SequenceRunState{run_id: run_id}}
      when is_binary(run_id) ->
        Map.get(details, :run_id) == run_id

      _other ->
        false
    end
  end

  defp sequence_abort_applicable?(%__MODULE__{} = data, details) when is_map(details) do
    case {owner(data), sequence_run(data)} do
      {{:sequence_run, run_id}, %SequenceRunState{run_id: run_id}}
      when is_binary(run_id) ->
        Map.get(details, :run_id) == run_id

      _other ->
        false
    end
  end

  defp removed_entry_ids(
         %Workspace{} = current_workspace,
         %Workspace{} = next_workspace,
         kind
       ) do
    current_ids = entry_ids(current_workspace, kind)
    next_ids = entry_ids(next_workspace, kind)

    current_ids
    |> MapSet.difference(next_ids)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp entry_ids(%Workspace{} = workspace, kind) do
    workspace
    |> Workspace.list_kind(kind)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  defp normalize_active_adapters(adapters) when is_list(adapters) do
    adapters
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_artifact_runtime(statuses) when is_list(statuses) do
    Enum.reduce(statuses, %{}, fn status, artifact_runtime ->
      runtime = ArtifactRuntime.from_status(status)
      Map.put(artifact_runtime, runtime.id, runtime)
    end)
  end

  defp workspace_hash_payload(%Workspace{} = workspace) do
    Enum.map(
      [:hardware, :hmi_surface, :machine, :sequence, :simulator_config, :topology],
      fn kind ->
        entries =
          workspace
          |> Workspace.list_entries(kind)
          |> Enum.map(fn draft ->
            {Map.get(draft, :id), Build.digest(Map.get(draft, :source, ""))}
          end)

        {kind, entries}
      end
    )
  end
end
