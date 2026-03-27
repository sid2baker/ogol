defmodule Ogol.Topology.Registry do
  @moduledoc false

  @name __MODULE__
  @active_topology_key {:__ogol__, :active_topology}

  def child_spec(opts \\ []) do
    Registry.child_spec(Keyword.merge([keys: :unique, name: @name], opts))
  end

  def via(name) when is_atom(name) do
    {:via, Registry, {@name, name}}
  end

  def whereis(name) when is_atom(name) do
    case Registry.lookup(@name, name) do
      [{pid, _value}] when is_pid(pid) -> pid
      [] -> nil
    end
  end

  def claim_topology(descriptor) when is_map(descriptor) do
    case Registry.register(@name, @active_topology_key, descriptor) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, pid}} ->
        {:error, {:topology_already_running, active_topology() || %{pid: pid}}}
    end
  end

  def active_topology do
    case Registry.lookup(@name, @active_topology_key) do
      [{pid, descriptor}] ->
        Map.put(descriptor, :pid, pid)

      [] ->
        nil
    end
  end
end
