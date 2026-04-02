defmodule Ogol.Session.Data do
  @moduledoc false

  alias Ogol.Session.Workspace

  @type t :: %__MODULE__{
          workspace: Workspace.t()
        }

  @type kind :: Workspace.kind()
  @type runtime_operation ::
          {:compile_artifact, :hardware_config | :machine | :topology | :sequence, String.t()}
          | {:deploy_topology, String.t()}
          | {:stop_topology, String.t()}
          | :stop_active
          | :restart_active

  @type operation :: Workspace.operation() | runtime_operation()

  @type action ::
          {:compile_artifact, :hardware_config | :machine | :topology | :sequence, String.t(),
           Workspace.t()}
          | {:delete_artifact, :machine | :topology | :sequence | :hardware_config, String.t()}
          | {:deploy_topology, String.t(), Workspace.t()}
          | {:stop_topology, String.t()}
          | :stop_active
          | {:restart_active, Workspace.t()}

  @runtime_artifact_kinds [:machine, :topology, :sequence, :hardware_config]
  @compilable_kinds [:hardware_config, :machine, :topology, :sequence]

  defstruct workspace: nil

  def new, do: %__MODULE__{workspace: Workspace.new()}

  def workspace(%__MODULE__{workspace: %Workspace{} = workspace}), do: workspace

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

  def apply_operation(%__MODULE__{} = data, {:deploy_topology, id}) when is_binary(id) do
    with {:ok, _entry} <- fetch_entry(data, :topology, id) do
      data
      |> with_actions()
      |> add_action({:deploy_topology, id, workspace(data)})
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def apply_operation(%__MODULE__{} = data, {:stop_topology, id} = action) when is_binary(id) do
    with {:ok, _entry} <- fetch_entry(data, :topology, id) do
      data
      |> with_actions()
      |> add_action(action)
      |> wrap_ok()
    else
      _ -> :error
    end
  end

  def apply_operation(%__MODULE__{} = data, :stop_active) do
    data
    |> with_actions()
    |> add_action(:stop_active)
    |> wrap_ok()
  end

  def apply_operation(%__MODULE__{} = data, :restart_active) do
    data
    |> with_actions()
    |> add_action({:restart_active, workspace(data)})
    |> wrap_ok()
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

  def loaded_inventory(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.loaded_inventory(workspace)
  end

  def loaded_revision(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.loaded_revision(workspace)
  end

  def workspace_session(%__MODULE__{workspace: %Workspace{} = workspace}) do
    Workspace.workspace_session(workspace)
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
end
