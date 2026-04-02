defmodule Ogol.Session.Data do
  @moduledoc false

  alias Ogol.Session.Workspace

  @type t :: %__MODULE__{
          workspace: Workspace.t()
        }

  @type kind :: Workspace.kind()
  @type operation :: Workspace.operation()

  @type action ::
          {:compile_artifact, :driver | :machine | :topology | :sequence, String.t()}
          | {:deploy_topology, String.t()}
          | {:stop_topology, String.t()}
          | :stop_active
          | :restart_active

  defstruct workspace: nil

  def new, do: %__MODULE__{workspace: Workspace.new()}

  def workspace(%__MODULE__{workspace: %Workspace{} = workspace}), do: workspace

  defdelegate driver_default_id(), to: Workspace
  defdelegate hardware_config_entry_id(), to: Workspace
  defdelegate machine_default_id(), to: Workspace
  defdelegate topology_default_id(), to: Workspace

  @spec apply_operation(t(), operation()) :: {:ok, t(), term(), [operation()]}
  def apply_operation(%__MODULE__{workspace: %Workspace{} = workspace} = data, operation) do
    {:ok, next_workspace, reply, operations} = Workspace.apply_operation(workspace, operation)
    {:ok, %__MODULE__{data | workspace: next_workspace}, reply, operations}
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

  @spec prepare_action(t(), action()) :: {:ok, action()} | {:error, term()}
  def prepare_action(%__MODULE__{} = data, {:compile_artifact, kind, id} = action)
      when kind in [:driver, :machine, :topology, :sequence] and is_binary(id) do
    require_entry(data, kind, id, action)
  end

  def prepare_action(%__MODULE__{} = data, {:deploy_topology, id} = action) when is_binary(id) do
    require_entry(data, :topology, id, action)
  end

  def prepare_action(%__MODULE__{} = data, {:stop_topology, id} = action) when is_binary(id) do
    require_entry(data, :topology, id, action)
  end

  def prepare_action(%__MODULE__{}, :stop_active), do: {:ok, :stop_active}
  def prepare_action(%__MODULE__{}, :restart_active), do: {:ok, :restart_active}
  def prepare_action(%__MODULE__{}, action), do: {:error, {:unknown_action, action}}

  defp require_entry(%__MODULE__{} = data, kind, id, action) do
    case fetch(data, kind, id) do
      nil -> {:error, {:unknown_workspace_entry, kind, id}}
      _entry -> {:ok, action}
    end
  end
end
