defmodule Ogol.Machine.Registry do
  @moduledoc false

  @name __MODULE__
  @pubsub Ogol.Runtime.PubSub

  def child_spec(opts \\ []) do
    Registry.child_spec(Keyword.merge([keys: :unique, name: @name], opts))
  end

  @doc """
  Returns a `{:via, Registry, ...}` tuple for registering a machine by id.
  """
  def via(machine_id) when is_atom(machine_id) do
    {:via, Registry, {@name, machine_id}}
  end

  @doc """
  Looks up a machine pid by its machine_id.
  """
  @spec whereis(atom()) :: pid() | nil
  def whereis(machine_id) when is_atom(machine_id) do
    case Registry.lookup(@name, machine_id) do
      [{pid, _value}] when is_pid(pid) -> pid
      [] -> nil
    end
  end

  @spec whereis_module(module()) :: pid() | nil
  def whereis_module(module) when is_atom(module) do
    case Registry.lookup(@name, module_key(module)) do
      [{pid, _value}] when is_pid(pid) -> pid
      [] -> nil
    end
  end

  @spec register_instance(atom() | nil, module()) ::
          :ok
          | {:error, {:machine_already_running, atom(), pid()}}
          | {:error, {:machine_module_already_running, module(), pid()}}
  def register_instance(machine_id, module) when is_atom(module) do
    with :ok <- register_machine_id(machine_id),
         {:ok, _owner} <- Registry.register(@name, module_key(module), module) do
      :ok
    else
      {:error, {:already_registered, pid}} ->
        unregister_machine_id(machine_id)
        {:error, {:machine_module_already_running, module, pid}}

      {:error, {:machine_id_conflict, machine_id, pid}} ->
        {:error, {:machine_already_running, machine_id, pid}}
    end
  end

  @doc """
  Signal topic for a specific signal from a specific machine instance.
  """
  def signal_topic(machine_id, signal_name) do
    "ogol:machine:#{machine_id}:signal:#{signal_name}"
  end

  @doc """
  Topic for all signals from a specific machine instance.
  """
  def signals_topic(machine_id) do
    "ogol:machine:#{machine_id}:signals"
  end

  @doc """
  Subscribe to a specific signal from a machine instance.
  """
  def subscribe_signal(machine_id, signal_name) do
    Phoenix.PubSub.subscribe(@pubsub, signal_topic(machine_id, signal_name))
  end

  @doc """
  Subscribe to all signals from a machine instance.
  """
  def subscribe_signals(machine_id) do
    Phoenix.PubSub.subscribe(@pubsub, signals_topic(machine_id))
  end

  @doc """
  Broadcast a signal to subscribers.
  """
  def broadcast_signal(machine_id, signal_name, data, meta) do
    message = {:ogol_signal, machine_id, signal_name, data, meta}

    Phoenix.PubSub.broadcast(@pubsub, signal_topic(machine_id, signal_name), message)
    Phoenix.PubSub.broadcast(@pubsub, signals_topic(machine_id), message)
  end

  defp register_machine_id(nil), do: :ok

  defp register_machine_id(machine_id) when is_atom(machine_id) do
    case Registry.register(@name, machine_id, machine_id) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, pid}} -> {:error, {:machine_id_conflict, machine_id, pid}}
    end
  end

  defp unregister_machine_id(nil), do: :ok

  defp unregister_machine_id(machine_id) when is_atom(machine_id),
    do: Registry.unregister(@name, machine_id)

  defp module_key(module), do: {:module, module}
end
