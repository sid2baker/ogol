defmodule Ogol.Session.Data do
  @moduledoc false

  alias Ogol.Session.Workspace

  @type t :: %__MODULE__{
          workspace: Workspace.t()
        }

  @type kind :: Workspace.kind()
  @type runtime_operation ::
          {:compile_artifact, :driver | :machine | :topology | :sequence, String.t()}
          | {:deploy_topology, String.t()}
          | {:stop_topology, String.t()}
          | :stop_active
          | :restart_active

  @type operation :: Workspace.operation() | runtime_operation()

  @type action ::
          {:compile_artifact, :driver | :machine | :topology | :sequence, String.t(),
           Workspace.t()}
          | {:delete_artifact, :driver | :machine | :topology | :sequence | :hardware_config,
             String.t()}
          | {:deploy_topology, String.t(), Workspace.t()}
          | {:stop_topology, String.t()}
          | :stop_active
          | {:restart_active, Workspace.t()}

  @runtime_artifact_kinds [:driver, :machine, :topology, :sequence, :hardware_config]
  @compilable_kinds [:driver, :machine, :topology, :sequence]

  defstruct workspace: nil

  def new, do: %__MODULE__{workspace: Workspace.new()}

  def workspace(%__MODULE__{workspace: %Workspace{} = workspace}), do: workspace

  defdelegate driver_default_id(), to: Workspace
  defdelegate hardware_config_entry_id(), to: Workspace
  defdelegate machine_default_id(), to: Workspace
  defdelegate topology_default_id(), to: Workspace

  @spec apply_operation(t(), operation()) ::
          {:ok, t(), term(), [operation()], [action()]} | :error
  def apply_operation(data, operation)

  def apply_operation(%__MODULE__{} = data, {:compile_artifact, kind, id})
      when kind in @compilable_kinds and is_binary(id) do
    case with_entry_action(data, kind, id, fn workspace ->
           {:compile_artifact, kind, id, workspace}
         end) do
      :error -> :error
      data_actions -> wrap_ok(data_actions)
    end
  end

  def apply_operation(%__MODULE__{} = data, {:deploy_topology, id}) when is_binary(id) do
    case with_entry_action(data, :topology, id, fn workspace ->
           {:deploy_topology, id, workspace}
         end) do
      :error -> :error
      data_actions -> wrap_ok(data_actions)
    end
  end

  def apply_operation(%__MODULE__{} = data, {:stop_topology, id} = action) when is_binary(id) do
    case with_entry_action(data, :topology, id, fn _workspace -> action end) do
      :error -> :error
      data_actions -> wrap_ok(data_actions)
    end
  end

  def apply_operation(%__MODULE__{} = data, :stop_active) do
    data
    |> with_actions(:ok, [])
    |> add_action(:stop_active)
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, :restart_active) do
    data
    |> with_actions(:ok, [])
    |> add_action({:restart_active, workspace(data)})
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:delete_entry, kind, _id} = operation)
      when kind in @runtime_artifact_kinds do
    current_workspace = workspace(data)

    data
    |> apply_workspace_operation(operation)
    |> with_actions()
    |> add_delete_actions(current_workspace, kind)
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:replace_entries, kind, _drafts} = operation)
      when kind in @runtime_artifact_kinds do
    current_workspace = workspace(data)

    data
    |> apply_workspace_operation(operation)
    |> with_actions()
    |> add_delete_actions(current_workspace, kind)
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, {:reset_kind, kind} = operation)
      when kind in @runtime_artifact_kinds do
    current_workspace = workspace(data)

    data
    |> apply_workspace_operation(operation)
    |> with_actions()
    |> add_delete_actions(current_workspace, kind)
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, operation) do
    data
    |> apply_workspace_operation(operation)
    |> with_actions()
    |> wrap_ok()
  end

  def list_kind(%__MODULE__{workspace: %Workspace{} = workspace}, kind) when is_atom(kind),
    do: Workspace.list_kind(workspace, kind)

  def list_entries(%__MODULE__{workspace: %Workspace{} = workspace}, kind),
    do: Workspace.list_entries(workspace, kind)

  def fetch(%__MODULE__{workspace: %Workspace{} = workspace}, kind, id)
      when is_atom(kind) and is_binary(id),
      do: Workspace.fetch(workspace, kind, id)

  def current_hardware_config(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.current_hardware_config(workspace)
  end

  def loaded_inventory(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.loaded_inventory(workspace)
  end

  def loaded_revision(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.loaded_revision(workspace)
  end

  def workspace_session(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.workspace_session(workspace)
  end

  defp with_entry_action(%__MODULE__{} = data, kind, id, action_builder)
       when is_function(action_builder, 1) do
    case fetch(data, kind, id) do
      nil ->
        :error

      _entry ->
        data
        |> with_actions(:ok, [])
        |> add_action(action_builder.(workspace(data)))
    end
  end

  defp apply_workspace_operation(
         %__MODULE__{workspace: %Workspace{} = workspace} = data,
         operation
       ) do
    {reply, next_workspace, operations} = Workspace.reduce(workspace, operation)
    {%__MODULE__{data | workspace: next_workspace}, reply, operations}
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

  defp with_actions({%__MODULE__{} = data, reply, operations}, actions \\ []) do
    {data, reply, operations, actions}
  end

  defp with_actions(%__MODULE__{} = data, reply, operations) when is_list(operations) do
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
end
