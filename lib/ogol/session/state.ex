defmodule Ogol.Session.State do
  @moduledoc false

  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Studio.Build
  alias Ogol.Session.{ArtifactRuntime, RuntimeState, SequenceRunState, Workspace}

  @type t :: %__MODULE__{
          workspace: Workspace.t(),
          runtime: RuntimeState.t(),
          artifact_runtime: %{optional(ArtifactRuntime.key()) => ArtifactRuntime.t()},
          sequence_run: SequenceRunState.t()
        }

  @type kind :: Workspace.kind()
  @type runtime_realization :: RuntimeState.realization()
  @type runtime_operation ::
          {:compile_artifact, :hardware_config | :machine | :topology | :sequence, String.t()}
          | {:set_desired_runtime, runtime_realization()}
          | {:start_sequence_run, String.t()}
          | :cancel_sequence_run
          | :reset_runtime_state
          | {:replace_artifact_runtime, [map()]}
          | {:runtime_started, runtime_realization(), map()}
          | {:runtime_stopped, map()}
          | {:runtime_failed, runtime_realization(), term()}
          | {:sequence_run_started, map()}
          | {:sequence_run_advanced, map()}
          | {:sequence_run_completed, map()}
          | {:sequence_run_failed, map()}
          | {:sequence_run_cancelled, map()}

  @type operation :: Workspace.operation() | runtime_operation()

  @type action ::
          {:compile_artifact, :hardware_config | :machine | :topology | :sequence, String.t(),
           Workspace.t()}
          | {:delete_artifact,
             :machine | :topology | :sequence | :hardware_config | :simulator_config, String.t()}
          | {:reconcile_runtime, Workspace.t(), RuntimeState.t()}
          | {:start_sequence_run, String.t(), module(), RuntimeState.t()}
          | :cancel_sequence_run

  @runtime_artifact_kinds [:machine, :topology, :sequence, :hardware_config]
  @compilable_kinds [:hardware_config, :machine, :topology, :sequence]

  defstruct workspace: nil,
            runtime: %RuntimeState{},
            artifact_runtime: %{},
            sequence_run: %SequenceRunState{}

  def new,
    do: %__MODULE__{
      workspace: Workspace.new(),
      runtime: %RuntimeState{},
      artifact_runtime: %{},
      sequence_run: %SequenceRunState{}
    }

  def workspace(%__MODULE__{workspace: %Workspace{} = workspace}), do: workspace
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
    |> put_sequence_run(%SequenceRunState{})
    |> add_action({:reconcile_runtime, workspace(data), next_runtime})
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:start_sequence_run, sequence_id} = operation)
      when is_binary(sequence_id) do
    with {:ok, _entry} <- fetch_entry(data, :sequence, sequence_id),
         {:ok, %RuntimeState{} = current_runtime} <- running_runtime(data),
         true <- runtime_realized?(data),
         module when is_atom(module) <- runtime_current(data, :sequence, sequence_id) do
      next_sequence_run = %SequenceRunState{
        status: :starting,
        sequence_id: sequence_id,
        sequence_module: module,
        deployment_id: current_runtime.deployment_id,
        topology_module: current_runtime.active_topology_module
      }

      data
      |> with_actions(:ok, [operation])
      |> put_sequence_run(next_sequence_run)
      |> add_action({:start_sequence_run, sequence_id, module, current_runtime})
      |> wrap_ok()
    else
      _other ->
        :error
    end
  end

  def apply_operation(%__MODULE__{} = data, :cancel_sequence_run = operation) do
    case sequence_run(data) do
      %SequenceRunState{status: status} when status in [:starting, :running] ->
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
    |> put_runtime(%RuntimeState{})
    |> put_artifact_runtime(%{})
    |> put_sequence_run(%SequenceRunState{})
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
    |> put_sequence_run(%SequenceRunState{})
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:runtime_stopped, details} = operation)
      when is_map(details) do
    next_runtime =
      runtime(data)
      |> Map.put(:observed, :stopped)
      |> Map.put(:status, :idle)
      |> Map.put(:deployment_id, nil)
      |> Map.put(:active_topology_module, nil)
      |> Map.put(:active_adapters, [])
      |> Map.put(:realized_workspace_hash, Map.get(details, :realized_workspace_hash))
      |> Map.put(:last_error, nil)

    data
    |> with_actions(:ok, [operation])
    |> put_runtime(next_runtime)
    |> put_sequence_run(%SequenceRunState{})
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
      |> Map.put(:deployment_id, nil)
      |> Map.put(:active_topology_module, nil)
      |> Map.put(:active_adapters, [])
      |> Map.put(:realized_workspace_hash, nil)
      |> Map.put(:last_error, reason)

    data
    |> with_actions(:ok, [operation])
    |> put_runtime(next_runtime)
    |> put_sequence_run(%SequenceRunState{})
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

  def apply_operation(%__MODULE__{} = data, {:sequence_run_completed, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
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
      |> put_sequence_run(SequenceRunState.from_snapshot(:failed, snapshot))
      |> wrap_ok()
    else
      data
      |> with_actions(:ok, [operation])
      |> wrap_ok()
    end
  end

  def apply_operation(%__MODULE__{} = data, {:sequence_run_cancelled, snapshot} = operation)
      when is_map(snapshot) do
    if sequence_feedback_applicable?(data, snapshot) do
      data
      |> with_actions(:ok, [operation])
      |> put_sequence_run(SequenceRunState.from_snapshot(:cancelled, snapshot))
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
    with {:ok, next_workspace, reply, operations} <-
           Workspace.apply_operation(workspace(data), operation) do
      data
      |> with_actions(reply, operations)
      |> put_workspace(next_workspace)
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

  def hardware_config_model(%__MODULE__{workspace: %Workspace{} = workspace}, id)
      when is_binary(id) do
    Workspace.hardware_config_model(workspace, id)
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
    with deployment_id when is_binary(deployment_id) <- Map.get(snapshot, :deployment_id),
         %RuntimeState{deployment_id: ^deployment_id} <- runtime(data) do
      true
    else
      _other -> false
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

  defp put_runtime(
         {%__MODULE__{} = data, reply, operations, actions},
         %RuntimeState{} = runtime
       ) do
    {%__MODULE__{data | runtime: runtime}, reply, operations, actions}
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
      [:hardware_config, :hmi_surface, :machine, :sequence, :simulator_config, :topology],
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
