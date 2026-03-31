defmodule Ogol.Runtime.Target do
  @moduledoc false

  alias Ogol.Runtime.Data
  alias Ogol.Topology.Runtime, as: TopologyRuntime

  @type resolved_machine_runtime :: %{
          pid: pid(),
          state_name: atom(),
          data: Data.t(),
          module: module()
        }

  @spec resolve_machine_pid(pid() | atom()) :: {:ok, pid()} | {:error, term()}
  def resolve_machine_pid(target) do
    with {:ok, %{pid: pid}} <- resolve_machine_runtime(target) do
      {:ok, pid}
    end
  end

  @spec resolve_machine_pid!(pid() | atom()) :: pid()
  def resolve_machine_pid!(target) do
    case resolve_machine_pid(target) do
      {:ok, pid} ->
        pid

      {:error, {:target_unavailable, unavailable_target}} ->
        raise ArgumentError,
              "machine target #{inspect(unavailable_target)} is not available in runtime"

      {:error, reason} ->
        raise ArgumentError, "machine target #{inspect(target)} is invalid: #{inspect(reason)}"
    end
  end

  @spec resolve_machine_runtime(pid() | atom()) ::
          {:ok, resolved_machine_runtime()} | {:error, term()}
  def resolve_machine_runtime(target)

  def resolve_machine_runtime(machine_id) when is_atom(machine_id) do
    case Ogol.Machine.Registry.whereis(machine_id) do
      pid when is_pid(pid) -> resolve_machine_runtime(pid)
      nil -> {:error, {:target_unavailable, machine_id}}
    end
  end

  def resolve_machine_runtime(pid) when is_pid(pid) do
    case safe_get_state(pid) do
      {state_name, %Data{} = data} when is_atom(state_name) ->
        module = data.meta[:machine_module]

        if is_atom(module) and function_exported?(module, :skills, 0) do
          {:ok, %{pid: pid, state_name: state_name, data: data, module: module}}
        else
          {:error, {:target_unavailable, pid}}
        end

      %TopologyRuntime{root_name: root_name} ->
        resolve_machine_runtime(root_name)

      _other ->
        {:error, {:target_unavailable, pid}}
    end
  end

  @spec machine_id(pid() | atom()) :: {:ok, atom()} | {:error, term()}
  def machine_id(target) do
    with {:ok, %{data: %Data{machine_id: machine_id}}} <- resolve_machine_runtime(target) do
      {:ok, machine_id}
    end
  end

  defp safe_get_state(pid) do
    :sys.get_state(pid)
  catch
    :exit, _reason -> nil
  end
end
