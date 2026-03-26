defmodule Ogol.HMI.CommandGateway do
  @moduledoc false

  alias Ogol.HMI.{RuntimeIndex, RuntimeNotifier, SnapshotStore}
  alias Ogol.Machine.Info

  @default_timeout 5_000

  @spec request(atom(), atom(), map(), map(), timeout()) :: {:ok, term()} | {:error, term()}
  def request(machine_id, name, data \\ %{}, meta \\ %{}, timeout \\ @default_timeout)
      when is_atom(machine_id) and is_atom(name) and is_map(data) and is_map(meta) do
    operator_meta = operator_meta(meta)

    with {:ok, module} <- machine_module(machine_id),
         :ok <- ensure_declared(module, :request, name),
         {:ok, pid} <- machine_pid(machine_id),
         {:ok, reply} <- dispatch_request(pid, name, data, operator_meta, timeout) do
      RuntimeNotifier.emit(:operator_request_sent,
        machine_id: machine_id,
        source: __MODULE__,
        payload: %{name: name, data: data, reply: reply},
        meta: operator_meta
      )

      {:ok, reply}
    else
      {:error, reason} = error ->
        emit_failure(machine_id, :request, name, data, operator_meta, reason)
        error
    end
  end

  @spec event(atom(), atom(), map(), map()) :: :ok | {:error, term()}
  def event(machine_id, name, data \\ %{}, meta \\ %{})
      when is_atom(machine_id) and is_atom(name) and is_map(data) and is_map(meta) do
    operator_meta = operator_meta(meta)

    with {:ok, module} <- machine_module(machine_id),
         :ok <- ensure_declared(module, :event, name),
         {:ok, pid} <- machine_pid(machine_id) do
      :ok = Ogol.event(pid, name, data, operator_meta)

      RuntimeNotifier.emit(:operator_event_sent,
        machine_id: machine_id,
        source: __MODULE__,
        payload: %{name: name, data: data},
        meta: operator_meta
      )

      :ok
    else
      {:error, reason} = error ->
        emit_failure(machine_id, :event, name, data, operator_meta, reason)
        error
    end
  end

  defp machine_module(machine_id) do
    case SnapshotStore.get_machine(machine_id) do
      %{module: module} when is_atom(module) ->
        if Code.ensure_loaded?(module) do
          {:ok, module}
        else
          {:error, :module_unavailable}
        end

      _ ->
        {:error, :machine_unavailable}
    end
  end

  defp machine_pid(machine_id) do
    case RuntimeIndex.get({:machine, machine_id}) do
      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          {:error, :machine_unavailable}
        end

      _ ->
        {:error, :machine_unavailable}
    end
  end

  defp ensure_declared(module, :request, name) do
    ensure_known_name(Info.requests(module), name, :request)
  end

  defp ensure_declared(module, :event, name) do
    ensure_known_name(Info.events(module), name, :event)
  end

  defp ensure_known_name(items, name, kind) do
    if Enum.any?(items, &(&1.name == name)) do
      :ok
    else
      {:error, {:unknown_operator_action, kind, name}}
    end
  end

  defp dispatch_request(pid, name, data, meta, timeout) do
    {:ok, Ogol.request(pid, name, data, meta, timeout)}
  catch
    :exit, reason -> {:error, {:request_failed, reason}}
  end

  defp emit_failure(machine_id, action, name, data, meta, reason) do
    RuntimeNotifier.emit(:operator_action_failed,
      machine_id: machine_id,
      source: __MODULE__,
      payload: %{action: action, name: name, data: data, reason: reason},
      meta: meta
    )
  end

  defp operator_meta(meta) do
    meta
    |> Map.put_new(:origin, :operator)
    |> Map.put_new(:gateway, __MODULE__)
  end
end
