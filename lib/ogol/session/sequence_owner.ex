defmodule Ogol.Session.SequenceOwner do
  @moduledoc false

  use GenServer

  alias Ogol.Sequence.Runner
  alias Ogol.Sequence.Runtime, as: SequenceRuntime
  alias Ogol.Session.{RuntimeState, SequenceRunState}
  alias Ogol.Topology

  @dispatch_timeout 15_000

  defmodule OwnerState do
    @moduledoc false

    @type active_t :: %{
            pid: pid(),
            monitor_ref: reference(),
            topology_scope: atom(),
            deployment_id: String.t(),
            run_id: String.t(),
            sequence_id: String.t(),
            sequence_module: module()
          }

    @type t :: %__MODULE__{
            active: active_t() | nil
          }

    defstruct active: nil
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec start_run(String.t(), module(), RuntimeState.t()) ::
          {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def start_run(sequence_id, sequence_module, %RuntimeState{} = runtime_state)
      when is_binary(sequence_id) and is_atom(sequence_module) do
    GenServer.call(
      __MODULE__,
      {:start_run, sequence_id, sequence_module, runtime_state},
      @dispatch_timeout
    )
  end

  @spec cancel_run() :: {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def cancel_run do
    GenServer.call(__MODULE__, :cancel_run, @dispatch_timeout)
  end

  @spec reset() :: :ok | {:error, term()}
  def reset do
    case cancel_run() do
      {:ok, _operations} -> :ok
      {:error, :sequence_run_not_active} -> :ok
      other -> other
    end
  end

  @impl true
  def init(_opts) do
    {:ok, %OwnerState{}}
  end

  @impl true
  def handle_call(
        {:start_run, sequence_id, sequence_module, %RuntimeState{} = runtime_state},
        _from,
        %OwnerState{} = state
      ) do
    {reply, next_state} = do_start_run(state, sequence_id, sequence_module, runtime_state)
    {:reply, reply, next_state}
  end

  def handle_call(:cancel_run, _from, %OwnerState{} = state) do
    {reply, next_state} = do_cancel_run(state)
    {:reply, reply, next_state}
  end

  @impl true
  def handle_info(
        {:sequence_progress, pid, event, snapshot},
        %OwnerState{active: %{pid: pid} = active} = state
      )
      when event in [:started, :advanced, :completed, :failed] do
    operation =
      case event do
        :started -> {:sequence_run_started, snapshot}
        :advanced -> {:sequence_run_advanced, snapshot}
        :completed -> {:sequence_run_completed, snapshot}
        :failed -> {:sequence_run_failed, snapshot}
      end

    _ = Ogol.Session.dispatch(operation)

    next_state =
      if event in [:completed, :failed] do
        clear_active_runtime(state, active)
      else
        state
      end

    {:noreply, next_state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %OwnerState{active: %{pid: pid, monitor_ref: ref} = active} = state
      ) do
    next_state = clear_active_runtime(state, active)

    case normalize_exit_reason(reason) do
      :normal ->
        {:noreply, next_state}

      :shutdown ->
        {:noreply, next_state}

      unexpected ->
        _ =
          Ogol.Session.dispatch(
            {:sequence_run_failed,
             %{
               sequence_id: active.sequence_id,
               sequence_module: active.sequence_module,
               run_id: active.run_id,
               deployment_id: active.deployment_id,
               topology_module: nil,
               current_procedure: nil,
               current_step_id: nil,
               current_step_label: nil,
               started_at: nil,
               finished_at: System.system_time(:millisecond),
               last_error: {:sequence_runner_exited, unexpected}
             }}
          )

        {:noreply, next_state}
    end
  end

  def handle_info(_message, %OwnerState{} = state) do
    {:noreply, state}
  end

  defp do_start_run(%OwnerState{} = state, sequence_id, sequence_module, runtime_state) do
    with :ok <- ensure_runtime_running(runtime_state),
         :ok <- ensure_no_active_run(state),
         {:ok, topology_scope} <- topology_scope(runtime_state),
         {:ok, %Ogol.Sequence.Model{sequence: sequence} = model} <-
           fetch_sequence_model(sequence_module),
         :ok <- ensure_sequence_matches_runtime(sequence, runtime_state),
         run_id <- next_run_id(),
         {:ok, pid} <-
           SequenceRuntime.start_run(
             topology_scope,
             run_id: run_id,
             sequence_id: sequence_id,
             sequence_module: sequence_module,
             sequence_model: model,
             deployment_id: runtime_state.deployment_id,
             topology_module: runtime_state.active_topology_module,
             owner: self()
           ),
         {:ok, snapshot} <- Runner.snapshot(pid) do
      monitor_ref = Process.monitor(pid)

      next_state =
        %OwnerState{
          active: %{
            pid: pid,
            monitor_ref: monitor_ref,
            topology_scope: topology_scope,
            deployment_id: runtime_state.deployment_id,
            run_id: run_id,
            sequence_id: sequence_id,
            sequence_module: sequence_module
          }
        }

      {{:ok, [{:sequence_run_started, snapshot}]}, next_state}
    else
      {:error, {:already_started, _pid}} ->
        {{:ok,
          [
            {:sequence_run_failed,
             failure_snapshot(
               sequence_id,
               sequence_module,
               runtime_state,
               :sequence_already_running
             )}
          ]}, state}

      {:error, reason} ->
        {{:ok,
          [
            {:sequence_run_failed,
             failure_snapshot(sequence_id, sequence_module, runtime_state, reason)}
          ]}, state}
    end
  end

  defp do_cancel_run(%OwnerState{active: nil} = state) do
    {{:error, :sequence_run_not_active}, state}
  end

  defp do_cancel_run(%OwnerState{active: %{topology_scope: topology_scope} = active} = state) do
    case SequenceRuntime.cancel_run(topology_scope) do
      {:ok, snapshot} ->
        next_state = clear_active_runtime(state, active)
        {{:ok, [{:sequence_run_cancelled, snapshot}]}, next_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp ensure_runtime_running(%RuntimeState{
         observed: observed,
         deployment_id: deployment_id,
         active_topology_module: active_topology_module
       })
       when observed in [{:running, :simulation}, {:running, :live}] and
              is_binary(deployment_id) and is_atom(active_topology_module),
       do: :ok

  defp ensure_runtime_running(_runtime_state), do: {:error, :topology_not_running}

  defp ensure_no_active_run(%OwnerState{active: nil}), do: :ok

  defp ensure_no_active_run(%OwnerState{active: %{sequence_id: sequence_id}}),
    do: {:error, {:sequence_run_active, sequence_id}}

  defp topology_scope(%RuntimeState{active_topology_module: module}) when is_atom(module) do
    {:ok, Topology.scope(module)}
  end

  defp topology_scope(_runtime_state), do: {:error, :missing_active_topology}

  defp fetch_sequence_model(sequence_module) when is_atom(sequence_module) do
    cond do
      not Code.ensure_loaded?(sequence_module) ->
        {:error, :sequence_module_not_loaded}

      not function_exported?(sequence_module, :__ogol_sequence__, 0) ->
        {:error, :sequence_module_not_compiled}

      true ->
        {:ok, sequence_module.__ogol_sequence__()}
    end
  end

  defp ensure_sequence_matches_runtime(%{topology: topology}, %RuntimeState{
         active_topology_module: active_topology_module
       })
       when topology == active_topology_module,
       do: :ok

  defp ensure_sequence_matches_runtime(_sequence, _runtime_state),
    do: {:error, :sequence_topology_mismatch}

  defp failure_snapshot(sequence_id, sequence_module, runtime_state, reason) do
    %SequenceRunState{}
    |> Map.from_struct()
    |> Map.put(:sequence_id, sequence_id)
    |> Map.put(:sequence_module, sequence_module)
    |> Map.put(:deployment_id, runtime_state.deployment_id)
    |> Map.put(:topology_module, runtime_state.active_topology_module)
    |> Map.put(:finished_at, System.system_time(:millisecond))
    |> Map.put(:last_error, reason)
  end

  defp clear_active_runtime(%OwnerState{} = state, %{monitor_ref: monitor_ref})
       when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
    %OwnerState{state | active: nil}
  end

  defp next_run_id do
    "sr#{System.unique_integer([:positive])}"
  end

  defp normalize_exit_reason({:shutdown, reason}), do: normalize_exit_reason(reason)
  defp normalize_exit_reason(:normal), do: :normal
  defp normalize_exit_reason(:shutdown), do: :shutdown
  defp normalize_exit_reason(reason), do: reason
end
