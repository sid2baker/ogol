defmodule Ogol do
  @moduledoc """
  Public machine interface for Ogol.

  This module intentionally exposes a breaking, cleaner API centered on:

  - `skills`
  - `status`
  - `invoke/4`

  Low-level request/event delivery remains internal runtime plumbing.
  """

  alias Ogol.HMI.{RuntimeIndex, SnapshotStore}
  alias Ogol.Interface
  alias Ogol.Runtime.Data
  alias Ogol.Runtime.Delivery
  alias Ogol.Skill
  alias Ogol.Status

  @default_timeout 5_000

  @spec skills(term()) :: [Skill.t()]
  def skills(target) do
    case resolve_interface_target(target) do
      {:ok, %{module: module, available?: available?}} ->
        module.__ogol_interface__().skills
        |> Enum.filter(& &1.visible?)
        |> Enum.map(fn %Skill{} = skill -> %{skill | available?: available?} end)

      :error ->
        []
    end
  end

  @spec skill(term(), atom()) :: Skill.t() | nil
  def skill(target, name) when is_atom(name) do
    Enum.find(skills(target), &(&1.name == name))
  end

  @spec invoke(term(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(target, name, args \\ %{}, opts \\ [])
      when is_atom(name) and is_map(args) and is_list(opts) do
    with {:ok, resolved} <- resolve_invoke_target(target),
         %Skill{} = skill <- skill(resolved.module, name) do
      meta = Keyword.get(opts, :meta, %{})
      timeout = Keyword.get(opts, :timeout, @default_timeout)

      case skill.kind do
        :request ->
          {:ok, Delivery.request(resolved.pid, name, args, meta, timeout)}

        :event ->
          :ok = Delivery.event(resolved.pid, name, args, meta)
          {:ok, :accepted}
      end
    else
      nil -> {:error, {:unknown_skill, name}}
      :error -> {:error, :target_unavailable}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:target_runtime_failure, reason}}
  end

  @spec status(term()) :: Status.t() | nil
  def status(target) do
    case resolve_status_source(target) do
      {:snapshot, snapshot, %Interface{} = interface} ->
        project_status(
          interface,
          snapshot.machine_id,
          snapshot.current_state,
          snapshot.health,
          snapshot.connected?,
          snapshot.facts,
          snapshot.outputs,
          snapshot.fields,
          snapshot.last_signal,
          snapshot.last_transition_at
        )

      {:runtime, machine_id, module, state_name, %Data{} = data} ->
        project_status(
          module.__ogol_interface__(),
          machine_id,
          state_name,
          infer_health(state_name),
          true,
          data.facts,
          data.outputs,
          data.fields,
          nil,
          nil
        )

      :error ->
        nil
    end
  end

  defp resolve_invoke_target(target) do
    with {:ok, resolved} <- resolve_runtime_target(target),
         :ok <- ensure_runtime_pid(resolved),
         true <- function_exported?(resolved.module, :__ogol_interface__, 0) do
      {:ok, resolved}
    else
      :target_unavailable -> {:error, :target_unavailable}
      false -> {:error, :module_unavailable}
      :error -> {:error, :target_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_interface_target(target) do
    case resolve_runtime_target(target) do
      {:ok, %{module: module}} = ok ->
        if function_exported?(module, :__ogol_interface__, 0), do: ok, else: :error

      :error ->
        resolve_module_target(target)

      other ->
        other
    end
  end

  defp resolve_status_source(target) do
    case resolve_runtime_target(target) do
      {:ok, %{pid: pid, module: module, machine_id: machine_id}} when is_pid(pid) ->
        case safe_get_state(pid) do
          {state_name, %Data{} = data} ->
            {:runtime, machine_id, module, state_name, data}

          _ ->
            resolve_status_source_from_snapshot(target)
        end

      _ ->
        resolve_status_source_from_snapshot(target)
    end
  end

  defp resolve_status_source_from_snapshot(target) do
    case resolve_snapshot_target(target) do
      {:ok, snapshot, module} ->
        {:snapshot, snapshot, module.__ogol_interface__()}

      :error ->
        :error
    end
  end

  defp resolve_snapshot_target(target) when is_atom(target) do
    case SnapshotStore.get_machine(target) do
      %{module: module} = snapshot when is_atom(module) ->
        if function_exported?(module, :__ogol_interface__, 0) do
          {:ok, snapshot, module}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp resolve_snapshot_target(%{machine_id: machine_id}) when is_atom(machine_id) do
    resolve_snapshot_target(machine_id)
  end

  defp resolve_snapshot_target(target) when is_pid(target) do
    with {:ok, %{machine_id: machine_id}} <- resolve_runtime_target(target) do
      resolve_snapshot_target(machine_id)
    else
      _ -> :error
    end
  end

  defp resolve_snapshot_target(_target), do: :error

  defp resolve_runtime_target(target) when is_pid(target) do
    cond do
      not Process.alive?(target) ->
        :error

      true ->
        case safe_get_state(target) do
          {state_name, %Data{} = data} when is_atom(state_name) ->
            module = data.meta[:machine_module]

            if is_atom(module) and function_exported?(module, :__ogol_interface__, 0) do
              {:ok,
               %{
                 pid: target,
                 module: module,
                 machine_id: data.machine_id,
                 available?: true
               }}
            else
              :error
            end

          _other ->
            with {:ok, brain_pid} <- safe_topology_brain_pid(target) do
              resolve_runtime_target(brain_pid)
            else
              _ -> resolve_runtime_from_indexes(target)
            end
        end
    end
  end

  defp resolve_runtime_target(target) when is_atom(target) do
    case resolve_module_target(target) do
      {:ok, %{module: _module}} = ok ->
        ok

      :error ->
        case Ogol.Topology.Registry.whereis(target) do
          pid when is_pid(pid) ->
            resolve_runtime_target(pid)

          _ ->
            case resolve_snapshot_target(target) do
              {:ok, snapshot, module} ->
                {pid, available?} =
                  case RuntimeIndex.get({:machine, snapshot.machine_id}) do
                    %{pid: pid} when is_pid(pid) ->
                      if Process.alive?(pid), do: {pid, true}, else: {nil, false}

                    _ ->
                      {nil, false}
                  end

                {:ok,
                 %{
                   pid: pid,
                   module: module,
                   machine_id: snapshot.machine_id,
                   available?: available?
                 }}

              :error ->
                case GenServer.whereis(target) do
                  pid when is_pid(pid) -> resolve_runtime_target(pid)
                  _ -> :error
                end
            end
        end
    end
  end

  defp resolve_runtime_target(%{machine_id: machine_id}) when is_atom(machine_id) do
    resolve_runtime_target(machine_id)
  end

  defp resolve_runtime_target(_target), do: :error

  defp resolve_module_target(target) when is_atom(target) do
    if Code.ensure_loaded?(target) and function_exported?(target, :__ogol_interface__, 0) do
      interface = target.__ogol_interface__()

      {:ok,
       %{
         pid: nil,
         module: target,
         machine_id: interface.machine_id,
         available?: nil
       }}
    else
      :error
    end
  end

  defp resolve_module_target(_target), do: :error

  defp resolve_runtime_from_indexes(pid) do
    case RuntimeIndex.find_machine_by_pid(pid) do
      {machine_id, %{pid: ^pid}} ->
        case resolve_snapshot_target(machine_id) do
          {:ok, _snapshot, module} ->
            {:ok, %{pid: pid, module: module, machine_id: machine_id, available?: true}}

          :error ->
            :error
        end

      nil ->
        case RuntimeIndex.find_topology_by_pid(pid) do
          {_topology_id, %{root_pid: root_pid}} when is_pid(root_pid) ->
            resolve_runtime_target(root_pid)

          _ ->
            :error
        end
    end
  end

  defp safe_topology_brain_pid(pid) do
    try do
      case GenServer.call(pid, :brain_pid, 100) do
        brain_pid when is_pid(brain_pid) -> {:ok, brain_pid}
        _ -> :error
      end
    catch
      :exit, _reason -> :error
    end
  end

  defp safe_get_state(pid) do
    :sys.get_state(pid)
  catch
    :exit, _reason -> nil
  end

  defp project_status(
         interface,
         machine_id,
         current_state,
         health,
         connected?,
         facts,
         outputs,
         fields,
         last_signal,
         last_transition_at
       ) do
    %Status{
      machine_id: machine_id,
      module: interface.module,
      current_state: current_state,
      health: health,
      connected?: connected?,
      facts: pick_public_values(facts, interface.status_spec.facts),
      outputs: pick_public_values(outputs, interface.status_spec.outputs),
      fields: pick_public_values(fields, interface.status_spec.fields),
      last_signal: last_signal,
      last_transition_at: last_transition_at
    }
  end

  defp pick_public_values(values, _spec_items) when values == %{}, do: %{}

  defp pick_public_values(values, spec_items) when is_map(values) do
    spec_items
    |> Enum.flat_map(fn %{name: name} ->
      case Map.fetch(values, name) do
        {:ok, value} -> [{name, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp infer_health(state) when state in [:running], do: :running
  defp infer_health(state) when state in [:idle, :waiting], do: :waiting
  defp infer_health(state) when state in [:fault, :faulted], do: :faulted
  defp infer_health(_state), do: :healthy

  defp ensure_runtime_pid(%{pid: pid}) when is_pid(pid), do: :ok
  defp ensure_runtime_pid(_resolved), do: :target_unavailable
end
