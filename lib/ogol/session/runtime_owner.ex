defmodule Ogol.Session.RuntimeOwner do
  @moduledoc false

  use GenServer

  alias Ogol.Hardware.Config
  alias Ogol.Runtime.Deployment
  alias Ogol.Session.{RuntimeState, State, Workspace}
  alias Ogol.Topology
  alias Ogol.Topology.Registry
  alias Ogol.Topology.Runtime, as: TopologyRuntime

  @dispatch_timeout 15_000

  defmodule OwnerState do
    @moduledoc false

    @type active_t :: %{
            pid: pid(),
            module: module(),
            topology_id: String.t(),
            topology_scope: atom(),
            deployment_id: String.t(),
            realization: RuntimeState.realization()
          }

    @type t :: %__MODULE__{
            next_deployment_number: pos_integer(),
            active: active_t() | nil,
            monitor_ref: reference() | nil
          }

    defstruct next_deployment_number: 1, active: nil, monitor_ref: nil
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec reconcile(Workspace.t(), RuntimeState.t()) ::
          {:ok, [State.runtime_operation()]} | {:error, term()}
  def reconcile(%Workspace{} = workspace, %RuntimeState{} = runtime_state) do
    GenServer.call(__MODULE__, {:reconcile, workspace, runtime_state}, @dispatch_timeout)
  end

  @spec reset() :: :ok | {:error, term()}
  def reset do
    GenServer.call(__MODULE__, :reset, @dispatch_timeout)
  end

  @impl true
  def init(_opts) do
    {:ok, %OwnerState{}}
  end

  @impl true
  def handle_call(
        {:reconcile, %Workspace{} = workspace, %RuntimeState{} = runtime_state},
        _from,
        %OwnerState{} = state
      ) do
    {reply, next_state} = reconcile_runtime(state, workspace, runtime_state)
    {:reply, reply, next_state}
  end

  def handle_call(:reset, _from, %OwnerState{} = state) do
    case force_stop_active_runtime(state) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {{:error, reason}, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, %OwnerState{} = state) do
    case state do
      %OwnerState{
        monitor_ref: ^ref,
        active: %{pid: ^pid, realization: realization}
      } ->
        dispatch_runtime_exit(realization, reason)
        {:noreply, clear_active_runtime(state)}

      _other ->
        {:noreply, state}
    end
  end

  defp reconcile_runtime(
         %OwnerState{} = state,
         _workspace,
         %RuntimeState{desired: :stopped}
       ) do
    case stop_active_runtime(state) do
      {:ok, next_state} ->
        {{:ok, [{:runtime_stopped, %{realized_workspace_hash: nil}}]}, next_state}

      {:noop, next_state} ->
        {{:ok, [{:runtime_stopped, %{realized_workspace_hash: nil}}]}, next_state}

      {:conflict, reason, next_state} ->
        {{:ok, [{:runtime_failed, :stopped, reason}]}, next_state}

      {{:error, reason}, next_state} ->
        {{:ok, [{:runtime_failed, :stopped, reason}]}, next_state}
    end
  end

  defp reconcile_runtime(
         %OwnerState{} = state,
         %Workspace{} = workspace,
         %RuntimeState{desired: realization}
       )
       when realization in [{:running, :simulation}, {:running, :live}] do
    with {:ok, topology_id} <- topology_id(workspace),
         :ok <- ensure_runtime_conflict_free(state, workspace, topology_id),
         {:ok, stopped_state} <- restart_if_same_topology(state, topology_id),
         {:ok, prepared, prepared_state} <-
           prepare_topology_runtime(stopped_state, workspace, topology_id),
         {:ok, next_state, details} <-
           start_topology_runtime(prepared_state, workspace, prepared, realization) do
      {{:ok, [{:runtime_started, realization, details}]}, next_state}
    else
      {:error, reason} ->
        {{:ok, [{:runtime_failed, realization, reason}]}, state}

      {:error, reason, %OwnerState{} = next_state} ->
        {{:ok, [{:runtime_failed, realization, reason}]}, next_state}
    end
  end

  defp prepare_topology_runtime(
         %OwnerState{} = state,
         %Workspace{} = workspace,
         topology_id
       ) do
    case Deployment.prepare_topology_runtime(workspace, topology_id) do
      {:ok, prepared} -> {:ok, prepared, state}
      {:error, reason} -> {:error, reason, state}
      other -> {:error, {:unexpected_topology_prepare_result, other}, state}
    end
  end

  defp start_topology_runtime(
         %OwnerState{} = state,
         %Workspace{} = workspace,
         %{
           topology_id: topology_id,
           module: module,
           topology_model: topology_model,
           hardware_configs: hardware_configs
         },
         realization
       ) do
    case TopologyRuntime.start(topology_model, hardware_configs: hardware_configs) do
      {:ok, pid} when is_pid(pid) ->
        deployment_id = next_deployment_id(state)
        monitor_ref = Process.monitor(pid)
        topology_scope = Topology.scope(module)

        next_state =
          %OwnerState{
            state
            | next_deployment_number: state.next_deployment_number + 1,
              active: %{
                pid: pid,
                module: module,
                topology_id: topology_id,
                topology_scope: topology_scope,
                deployment_id: deployment_id,
                realization: realization
              },
              monitor_ref: monitor_ref
          }

        details = %{
          deployment_id: deployment_id,
          active_topology_module: module,
          active_adapters: active_adapters(hardware_configs),
          realized_workspace_hash: State.workspace_hash(workspace)
        }

        {:ok, next_state, details}

      {:error, {:already_started, pid}} when is_pid(pid) ->
        {:error, {:topology_already_running, active_topology_descriptor()}, state}

      {:error, reason} ->
        {:error, normalize_start_error(reason), state}

      other ->
        {:error, {:invalid_topology_start_result, other}, state}
    end
  end

  defp ensure_runtime_conflict_free(%OwnerState{} = state, %Workspace{} = workspace, topology_id) do
    selected_module = selected_topology_module(workspace)

    cond do
      match?(%{topology_id: ^topology_id}, state.active) ->
        :ok

      match?(%{topology_id: _other}, state.active) ->
        {:error, {:different_topology_running, state.active.topology_id}}

      active = active_topology_descriptor() ->
        cond do
          active.module == selected_module ->
            {:error, {:topology_already_running, active}}

          true ->
            {:error, {:different_topology_running, Atom.to_string(active.topology_scope)}}
        end

      true ->
        :ok
    end
  end

  defp restart_if_same_topology(
         %OwnerState{active: %{topology_id: topology_id}} = state,
         topology_id
       ) do
    case stop_tracked_runtime(state) do
      {:ok, next_state} -> {:ok, next_state}
      {{:error, reason}, next_state} -> {:error, reason, next_state}
    end
  end

  defp restart_if_same_topology(%OwnerState{} = state, _topology_id), do: {:ok, state}

  defp stop_active_runtime(%OwnerState{active: nil} = state) do
    case active_topology_descriptor() do
      nil -> {:noop, state}
      _active -> {:conflict, :different_topology_running, state}
    end
  end

  defp stop_active_runtime(%OwnerState{} = state), do: stop_tracked_runtime(state)

  defp stop_tracked_runtime(%OwnerState{active: nil} = state), do: {:noop, state}

  defp stop_tracked_runtime(%OwnerState{} = state) do
    pid = state.active.pid
    state = demonitor_active_runtime(state)

    case stop_runtime(pid) do
      :ok -> {:ok, clear_active_runtime(state)}
      {:error, :noproc} -> {:ok, clear_active_runtime(state)}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp force_stop_active_runtime(%OwnerState{active: nil} = state) do
    case active_topology_descriptor() do
      %{pid: pid} when is_pid(pid) ->
        case stop_runtime(pid) do
          :ok -> {:ok, clear_active_runtime(state)}
          {:error, :noproc} -> {:ok, clear_active_runtime(state)}
          {:error, reason} -> {{:error, reason}, state}
        end

      _other ->
        {:ok, clear_active_runtime(state)}
    end
  end

  defp force_stop_active_runtime(%OwnerState{} = state), do: stop_tracked_runtime(state)

  defp demonitor_active_runtime(%OwnerState{monitor_ref: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %OwnerState{state | monitor_ref: nil}
  end

  defp demonitor_active_runtime(%OwnerState{} = state), do: state

  defp clear_active_runtime(%OwnerState{} = state) do
    %OwnerState{state | active: nil, monitor_ref: nil}
  end

  defp stop_runtime(pid) when is_pid(pid) do
    try do
      GenServer.stop(pid, :shutdown)
      :ok
    catch
      :exit, {:noproc, _} -> {:error, :noproc}
      :exit, :noproc -> {:error, :noproc}
      :exit, reason -> {:error, reason}
    end
  end

  defp dispatch_runtime_exit(realization, reason) do
    _ =
      Ogol.Session.dispatch(
        {:runtime_failed, realization, {:topology_exited, normalize_exit_reason(reason)}}
      )

    :ok
  end

  defp active_topology_descriptor do
    case Registry.active_topology() do
      %{module: module, topology_scope: topology_scope, pid: pid} = active
      when is_atom(module) and is_atom(topology_scope) and is_pid(pid) ->
        if Process.alive?(pid), do: active, else: nil

      _other ->
        nil
    end
  end

  defp selected_topology_module(%Workspace{} = workspace) do
    case topology_id(workspace) do
      {:ok, id} ->
        case Workspace.fetch(workspace, :topology, id) do
          %{model: %{module_name: module_name}} when is_binary(module_name) ->
            module_from_name!(module_name)

          %{source: source} when is_binary(source) ->
            case Ogol.Topology.Source.module_from_source(source) do
              {:ok, module} -> module
              _other -> nil
            end

          _other ->
            nil
        end

      _other ->
        nil
    end
  end

  defp topology_id(%Workspace{} = workspace) do
    case Workspace.list_entries(workspace, :topology) do
      [%{id: id}] when is_binary(id) ->
        {:ok, id}

      [] ->
        {:error, :no_topology_available}

      topologies ->
        {:error, {:multiple_topologies_present, Enum.map(topologies, & &1.id)}}
    end
  end

  defp active_adapters(hardware_configs) when is_map(hardware_configs) do
    hardware_configs
    |> Map.values()
    |> Enum.map(&Config.adapter/1)
    |> Enum.filter(&is_atom/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp next_deployment_id(%OwnerState{} = state), do: "d#{state.next_deployment_number}"

  defp module_from_name!(module_name) when is_binary(module_name) do
    module_name
    |> String.trim()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
    |> Module.concat()
  end

  defp normalize_start_error({:shutdown, _reason} = reason), do: reason

  defp normalize_start_error({:failed_to_start_child, _child, _reason} = reason),
    do: {:shutdown, reason}

  defp normalize_start_error({:already_started, _pid} = reason), do: reason
  defp normalize_start_error(reason), do: reason

  defp normalize_exit_reason({:shutdown, reason}), do: reason
  defp normalize_exit_reason(reason), do: reason
end
