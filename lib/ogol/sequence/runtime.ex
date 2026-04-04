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

  @spec snapshot(atom()) :: {:ok, map()} | {:error, term()}
  def snapshot(topology_scope) when is_atom(topology_scope) do
    case active_run(topology_scope) do
      pid when is_pid(pid) -> Runner.snapshot(pid)
      nil -> {:error, :sequence_run_not_active}
    end
  end

  @spec cancel_run(atom()) :: {:ok, map()} | {:error, term()}
  def cancel_run(topology_scope) when is_atom(topology_scope) do
    case active_run(topology_scope) do
      pid when is_pid(pid) -> Runner.cancel(pid)
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
