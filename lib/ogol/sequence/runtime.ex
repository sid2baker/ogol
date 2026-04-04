defmodule Ogol.Sequence.Runtime do
  @moduledoc false

  alias Ogol.Sequence.{Runner, RuntimeSupervisor}

  @spec start_run(atom(), keyword()) :: DynamicSupervisor.on_start_child() | {:error, term()}
  def start_run(topology_scope, opts) when is_atom(topology_scope) and is_list(opts) do
    with {:ok, supervisor} <- fetch_supervisor(topology_scope) do
      child_opts =
        opts
        |> Keyword.put(:name, Runner.via(topology_scope))
        |> Keyword.put(:topology_scope, topology_scope)

      DynamicSupervisor.start_child(supervisor, {Runner, child_opts})
    end
  end

  @spec active_run(atom()) :: pid() | nil
  def active_run(topology_scope) when is_atom(topology_scope) do
    Runner.whereis(topology_scope)
  end

  @spec begin_run(atom()) :: :ok | {:error, term()}
  def begin_run(topology_scope) when is_atom(topology_scope) do
    case active_run(topology_scope) do
      pid when is_pid(pid) -> Runner.begin(pid)
      nil -> {:error, :sequence_run_not_active}
    end
  end

  @spec request_abort(atom(), keyword()) :: :ok | {:error, term()}
  def request_abort(topology_scope, opts \\ []) when is_atom(topology_scope) and is_list(opts) do
    case active_run(topology_scope) do
      pid when is_pid(pid) -> Runner.request_abort(pid, opts)
      nil -> {:error, :sequence_run_not_active}
    end
  end

  @spec request_pause(atom(), keyword()) :: :ok | {:error, term()}
  def request_pause(topology_scope, opts \\ []) when is_atom(topology_scope) and is_list(opts) do
    case active_run(topology_scope) do
      pid when is_pid(pid) -> Runner.request_pause(pid, opts)
      nil -> {:error, :sequence_run_not_active}
    end
  end

  @spec request_resume(atom(), keyword()) :: :ok | {:error, term()}
  def request_resume(topology_scope, opts \\ []) when is_atom(topology_scope) and is_list(opts) do
    case active_run(topology_scope) do
      pid when is_pid(pid) -> Runner.request_resume(pid, opts)
      nil -> {:error, :sequence_run_not_active}
    end
  end

  @spec snapshot(atom()) :: {:ok, map()} | {:error, term()}
  def snapshot(topology_scope) when is_atom(topology_scope) do
    case active_run(topology_scope) do
      pid when is_pid(pid) -> Runner.snapshot(pid)
      nil -> {:error, :sequence_run_not_active}
    end
  end

  @spec stop_run(atom()) :: :ok | {:error, term()}
  def stop_run(topology_scope) when is_atom(topology_scope) do
    case active_run(topology_scope) do
      pid when is_pid(pid) -> Runner.stop(pid)
      nil -> {:error, :sequence_run_not_active}
    end
  end

  defp fetch_supervisor(topology_scope) do
    case RuntimeSupervisor.whereis(topology_scope) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :sequence_runtime_unavailable}
    end
  end
end
