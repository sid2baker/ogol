defmodule Ogol.Session.AutoController do
  @moduledoc false

  @behaviour :gen_statem

  alias Ogol.Sequence.Runner
  alias Ogol.Sequence.Runtime, as: SequenceRuntime
  alias Ogol.Session.{RuntimeFaultPolicy, RuntimeState, SequenceRunState}
  alias Ogol.Topology

  @dispatch_timeout 15_000

  @type command_class :: :read_only | :normal_operator | {:sequence_run, String.t()}

  defmodule ControllerState do
    @moduledoc false

    @type owner_t :: :manual_operator | {:sequence_run, String.t()}

    @type active_t :: %{
            pid: pid() | nil,
            monitor_ref: reference() | nil,
            topology_scope: atom(),
            topology_module: module(),
            policy: SequenceRunState.run_policy(),
            run_generation: String.t(),
            pause_requested?: boolean(),
            abort_requested?: boolean(),
            takeover_requested?: boolean(),
            deployment_id: String.t(),
            run_id: String.t(),
            sequence_id: String.t(),
            sequence_module: module(),
            last_snapshot: map() | nil
          }

    @type t :: %__MODULE__{
            owner: owner_t(),
            active: active_t() | nil,
            held_snapshot: map() | nil
          }

    defstruct owner: :manual_operator, active: nil, held_snapshot: nil
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: :gen_statem.start_ret()
  def start_link(opts \\ []) do
    :gen_statem.start_link({:local, __MODULE__}, __MODULE__, opts, [])
  end

  @spec start_run(String.t(), module(), RuntimeState.t(), SequenceRunState.run_policy()) ::
          {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def start_run(sequence_id, sequence_module, %RuntimeState{} = runtime_state, policy)
      when is_binary(sequence_id) and is_atom(sequence_module) and policy in [:once, :cycle] do
    :gen_statem.call(
      __MODULE__,
      {:start_run, sequence_id, sequence_module, runtime_state, policy},
      @dispatch_timeout
    )
  end

  @spec set_control_mode(Ogol.Session.State.control_mode()) ::
          {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def set_control_mode(control_mode) when control_mode in [:manual, :auto] do
    :gen_statem.call(__MODULE__, {:set_control_mode, control_mode}, @dispatch_timeout)
  end

  @spec cancel_run() :: {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def cancel_run do
    :gen_statem.call(__MODULE__, :cancel_run, @dispatch_timeout)
  end

  @spec acknowledge_run() :: {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def acknowledge_run do
    :gen_statem.call(__MODULE__, :acknowledge_run, @dispatch_timeout)
  end

  @spec pause_run() :: {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def pause_run do
    :gen_statem.call(__MODULE__, :pause_run, @dispatch_timeout)
  end

  @spec request_manual_takeover() :: {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def request_manual_takeover do
    :gen_statem.call(__MODULE__, :request_manual_takeover, @dispatch_timeout)
  end

  @spec resume_run() :: {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def resume_run do
    :gen_statem.call(__MODULE__, :resume_run, @dispatch_timeout)
  end

  @spec resume_held_run(RuntimeState.t()) ::
          {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def resume_held_run(%RuntimeState{} = runtime_state) do
    :gen_statem.call(__MODULE__, {:resume_held_run, runtime_state}, @dispatch_timeout)
  end

  @spec hold_run([term()]) :: {:ok, [Ogol.Session.State.operation()]} | {:error, term()}
  def hold_run(reasons) when is_list(reasons) do
    :gen_statem.call(__MODULE__, {:hold_run, reasons}, @dispatch_timeout)
  end

  @spec authorize_command(command_class()) :: :ok | {:error, term()}
  def authorize_command(command_class) do
    :gen_statem.call(__MODULE__, {:authorize_command, command_class}, @dispatch_timeout)
  end

  @spec reset() :: :ok | {:error, term()}
  def reset do
    :gen_statem.call(__MODULE__, :reset, @dispatch_timeout)
  end

  @impl true
  def callback_mode, do: :state_functions

  @impl true
  def init(_opts) do
    {:ok, :manual_idle, %ControllerState{}}
  end

  def manual_idle(:internal, {:dispatch, operation}, data) do
    dispatch_operation(operation)
    {:keep_state, data}
  end

  def manual_idle(
        {:call, from},
        {:set_control_mode, :manual},
        _data
      ) do
    {:keep_state_and_data, [{:reply, from, {:ok, []}}]}
  end

  def manual_idle(
        {:call, from},
        {:set_control_mode, :auto},
        data
      ) do
    {:next_state, :auto_idle, data,
     [{:reply, from, {:ok, [{:sync_auto_control, :auto, :manual_operator}]}}]}
  end

  def manual_idle(
        {:call, from},
        {:start_run, _sequence_id, _sequence_module, _runtime_state, _policy},
        _data
      ) do
    {:keep_state_and_data, [{:reply, from, {:error, :auto_mode_required}}]}
  end

  def manual_idle({:call, from}, :acknowledge_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_held}}]}
  end

  def manual_idle({:call, from}, :cancel_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def manual_idle({:call, from}, :pause_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def manual_idle({:call, from}, :request_manual_takeover, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def manual_idle({:call, from}, :resume_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def manual_idle({:call, from}, {:resume_held_run, _runtime_state}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def manual_idle({:call, from}, {:authorize_command, command_class}, _data) do
    {:keep_state_and_data, [{:reply, from, authorize_manual_command(command_class)}]}
  end

  def manual_idle({:call, from}, :reset, _data) do
    {:keep_state_and_data, [{:reply, from, :ok}]}
  end

  def manual_idle(_event_type, _event_content, _data) do
    :keep_state_and_data
  end

  def auto_idle(:internal, {:dispatch, operation}, data) do
    dispatch_operation(operation)
    {:keep_state, data}
  end

  def auto_idle(
        {:call, from},
        {:set_control_mode, :manual},
        data
      ) do
    {:next_state, :manual_idle, data,
     [{:reply, from, {:ok, [{:sync_auto_control, :manual, :manual_operator}]}}]}
  end

  def auto_idle(
        {:call, from},
        {:set_control_mode, :auto},
        _data
      ) do
    {:keep_state_and_data, [{:reply, from, {:ok, []}}]}
  end

  def auto_idle(
        {:call, from},
        {:start_run, sequence_id, sequence_module, runtime_state, policy},
        _data
      ) do
    with :ok <- ensure_runtime_running(runtime_state),
         {:ok, run_generation} <- runtime_generation(runtime_state),
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
             policy: policy,
             run_generation: run_generation,
             deployment_id: runtime_state.deployment_id,
             topology_module: runtime_state.active_topology_module,
             owner: self()
           ) do
      monitor_ref = Process.monitor(pid)

      snapshot = %{
        sequence_id: sequence_id,
        sequence_module: sequence_module,
        run_id: run_id,
        policy: policy,
        cycle_count: 0,
        run_generation: run_generation,
        deployment_id: runtime_state.deployment_id,
        topology_module: runtime_state.active_topology_module
      }

      next_data = %ControllerState{
        owner: {:sequence_run, run_id},
        active: %{
          pid: pid,
          monitor_ref: monitor_ref,
          topology_scope: topology_scope,
          topology_module: runtime_state.active_topology_module,
          policy: policy,
          run_generation: run_generation,
          pause_requested?: false,
          abort_requested?: false,
          takeover_requested?: false,
          deployment_id: runtime_state.deployment_id,
          run_id: run_id,
          sequence_id: sequence_id,
          sequence_module: sequence_module,
          last_snapshot: snapshot
        }
      }

      {:next_state, :auto_starting, next_data,
       [
         {:reply, from,
          {:ok,
           [
             {:sync_auto_control, :auto, {:sequence_run, run_id}},
             {:sequence_run_admitted, snapshot}
           ]}},
         {:next_event, :internal, :begin_active_run}
       ]}
    else
      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def auto_idle({:call, from}, :cancel_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def auto_idle({:call, from}, :acknowledge_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_held}}]}
  end

  def auto_idle({:call, from}, :pause_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def auto_idle({:call, from}, :request_manual_takeover, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def auto_idle({:call, from}, :resume_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def auto_idle({:call, from}, {:resume_held_run, _runtime_state}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def auto_idle({:call, from}, {:hold_run, _reasons}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_active}}]}
  end

  def auto_idle({:call, from}, {:authorize_command, command_class}, _data) do
    {:keep_state_and_data, [{:reply, from, authorize_auto_idle_command(command_class)}]}
  end

  def auto_idle({:call, from}, :reset, data) do
    {:next_state, :manual_idle, clear_active_runtime(data), [{:reply, from, :ok}]}
  end

  def auto_idle(_event_type, _event_content, _data) do
    :keep_state_and_data
  end

  def auto_starting(:internal, {:dispatch, operation}, data) do
    dispatch_operation(operation)
    {:keep_state, data}
  end

  def auto_starting({:call, from}, {:set_control_mode, _control_mode}, data) do
    {:keep_state, data, [{:reply, from, {:error, active_reason(data)}}]}
  end

  def auto_starting({:call, from}, :cancel_run, %ControllerState{} = data) do
    do_cancel_run(from, data)
  end

  def auto_starting({:call, from}, :acknowledge_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_held}}]}
  end

  def auto_starting({:call, from}, :pause_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_running}}]}
  end

  def auto_starting({:call, from}, :request_manual_takeover, %ControllerState{} = data) do
    do_request_manual_takeover(from, data)
  end

  def auto_starting({:call, from}, :resume_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_paused}}]}
  end

  def auto_starting({:call, from}, {:resume_held_run, _runtime_state}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_held}}]}
  end

  def auto_starting({:call, from}, {:hold_run, reasons}, %ControllerState{} = data) do
    do_hold_run(from, data, reasons)
  end

  def auto_starting({:call, from}, {:authorize_command, command_class}, %ControllerState{} = data) do
    {:keep_state, data, [{:reply, from, authorize_active_command(command_class, data)}]}
  end

  def auto_starting({:call, from}, :reset, %ControllerState{} = data) do
    case terminate_active_run(data) do
      {:ok, next_data} ->
        {:next_state, :manual_idle, next_data, [{:reply, from, :ok}]}

      {:error, :sequence_run_not_active} ->
        {:next_state, :manual_idle, clear_active_runtime(data), [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def auto_starting(
        {:call, from},
        {:start_run, _sequence_id, _sequence_module, _runtime_state, _policy},
        data
      ) do
    {:keep_state, data, [{:reply, from, {:error, active_reason(data)}}]}
  end

  def auto_starting(:internal, :begin_active_run, %ControllerState{active: %{pid: pid}} = data) do
    case Runner.begin(pid) do
      :ok ->
        {:keep_state, data}

      {:error, reason} ->
        next_data = clear_active_runtime(data)

        {:next_state, :auto_idle, next_data,
         dispatch_ops([
           release_control_operation(data),
           {:sequence_run_failed,
            failure_snapshot(data.active, {:sequence_runner_begin_failed, reason})}
         ])}
    end
  end

  def auto_starting(
        :info,
        {:sequence_progress, pid, :started, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = update_active_snapshot(data, snapshot)
    {:next_state, :auto_running, next_data, dispatch_ops([{:sequence_run_started, snapshot}])}
  end

  def auto_starting(
        :info,
        {:sequence_progress, pid, :resumed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = update_active_snapshot(data, snapshot)
    {:next_state, :auto_running, next_data, dispatch_ops([{:sequence_run_resumed, snapshot}])}
  end

  def auto_starting(
        :info,
        {:sequence_progress, pid, :advanced, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = update_active_snapshot(data, snapshot)
    {:next_state, :auto_running, next_data, dispatch_ops([{:sequence_run_started, snapshot}])}
  end

  def auto_starting(
        :info,
        {:sequence_progress, pid, :completed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_completed, snapshot}
     ])}
  end

  def auto_starting(
        :info,
        {:sequence_progress, pid, :aborted, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_aborted, snapshot}
     ])}
  end

  def auto_starting(
        :info,
        {:sequence_progress, pid, :failed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_failed, snapshot}
     ])}
  end

  def auto_starting(
        :info,
        {:DOWN, ref, :process, pid, reason},
        %ControllerState{active: %{pid: pid, monitor_ref: ref} = active} = data
      ) do
    next_data = clear_active_runtime(data)

    case normalize_exit_reason(reason) do
      :normal ->
        move_to_held(data, [{:sequence_runner_exited, :normal}])

      :shutdown ->
        move_to_held(data, [{:sequence_runner_exited, :shutdown}])

      unexpected ->
        {:next_state, :auto_idle, next_data,
         dispatch_ops([
           release_control_operation(data),
           {:sequence_run_failed, failure_snapshot(active, {:sequence_runner_exited, unexpected})}
         ])}
    end
  end

  def auto_starting(_event_type, _event_content, _data) do
    :keep_state_and_data
  end

  def auto_running(:internal, {:dispatch, operation}, data) do
    dispatch_operation(operation)
    {:keep_state, data}
  end

  def auto_running({:call, from}, {:set_control_mode, _control_mode}, data) do
    {:keep_state, data, [{:reply, from, {:error, active_reason(data)}}]}
  end

  def auto_running({:call, from}, :cancel_run, %ControllerState{} = data) do
    do_cancel_run(from, data)
  end

  def auto_running({:call, from}, :acknowledge_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_held}}]}
  end

  def auto_running({:call, from}, :pause_run, %ControllerState{} = data) do
    do_pause_run(from, data)
  end

  def auto_running({:call, from}, :request_manual_takeover, %ControllerState{} = data) do
    do_request_manual_takeover(from, data)
  end

  def auto_running({:call, from}, :resume_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_paused}}]}
  end

  def auto_running({:call, from}, {:resume_held_run, _runtime_state}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_held}}]}
  end

  def auto_running({:call, from}, {:hold_run, reasons}, %ControllerState{} = data) do
    do_hold_run(from, data, reasons)
  end

  def auto_running({:call, from}, {:authorize_command, command_class}, %ControllerState{} = data) do
    {:keep_state, data, [{:reply, from, authorize_active_command(command_class, data)}]}
  end

  def auto_running({:call, from}, :reset, %ControllerState{} = data) do
    case terminate_active_run(data) do
      {:ok, next_data} ->
        {:next_state, :manual_idle, next_data, [{:reply, from, :ok}]}

      {:error, :sequence_run_not_active} ->
        {:next_state, :manual_idle, clear_active_runtime(data), [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def auto_running(
        {:call, from},
        {:start_run, _sequence_id, _sequence_module, _runtime_state, _policy},
        data
      ) do
    {:keep_state, data, [{:reply, from, {:error, active_reason(data)}}]}
  end

  def auto_running(
        :info,
        {:sequence_progress, pid, :started, _snapshot},
        %ControllerState{active: %{pid: pid}}
      ) do
    :keep_state_and_data
  end

  def auto_running(
        :info,
        {:sequence_progress, pid, :advanced, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = update_active_snapshot(data, snapshot)
    {:keep_state, next_data, dispatch_ops([{:sequence_run_advanced, snapshot}])}
  end

  def auto_running(
        :info,
        {:sequence_progress, pid, :paused, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data =
      data
      |> update_active_snapshot(snapshot)
      |> clear_pause_request()

    {:next_state, :auto_paused, next_data, dispatch_ops([{:sequence_run_paused, snapshot}])}
  end

  def auto_running(
        :info,
        {:sequence_progress, pid, :resumed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = update_active_snapshot(data, snapshot)
    {:keep_state, next_data, dispatch_ops([{:sequence_run_resumed, snapshot}])}
  end

  def auto_running(
        :info,
        {:sequence_progress, pid, :completed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_completed, snapshot}
     ])}
  end

  def auto_running(
        :info,
        {:sequence_progress, pid, :aborted, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_aborted, snapshot}
     ])}
  end

  def auto_running(
        :info,
        {:sequence_progress, pid, :failed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_failed, snapshot}
     ])}
  end

  def auto_running(
        :info,
        {:DOWN, ref, :process, pid, reason},
        %ControllerState{active: %{pid: pid, monitor_ref: ref} = active} = data
      ) do
    next_data = clear_active_runtime(data)

    case normalize_exit_reason(reason) do
      :normal ->
        move_to_held(data, [{:sequence_runner_exited, :normal}])

      :shutdown ->
        move_to_held(data, [{:sequence_runner_exited, :shutdown}])

      unexpected ->
        {:next_state, :auto_idle, next_data,
         dispatch_ops([
           release_control_operation(data),
           {:sequence_run_failed, failure_snapshot(active, {:sequence_runner_exited, unexpected})}
         ])}
    end
  end

  def auto_running(_event_type, _event_content, _data) do
    :keep_state_and_data
  end

  def auto_paused(:internal, {:dispatch, operation}, data) do
    dispatch_operation(operation)
    {:keep_state, data}
  end

  def auto_paused({:call, from}, {:set_control_mode, _control_mode}, data) do
    {:keep_state, data, [{:reply, from, {:error, active_reason(data)}}]}
  end

  def auto_paused({:call, from}, :cancel_run, %ControllerState{} = data) do
    do_cancel_run(from, data)
  end

  def auto_paused({:call, from}, :acknowledge_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_held}}]}
  end

  def auto_paused({:call, from}, :pause_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:ok, []}}]}
  end

  def auto_paused({:call, from}, :request_manual_takeover, %ControllerState{} = data) do
    do_request_manual_takeover(from, data)
  end

  def auto_paused({:call, from}, :resume_run, %ControllerState{} = data) do
    do_resume_run(from, data)
  end

  def auto_paused({:call, from}, {:hold_run, reasons}, %ControllerState{} = data) do
    do_hold_run(from, data, reasons)
  end

  def auto_paused({:call, from}, {:resume_held_run, _runtime_state}, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_held}}]}
  end

  def auto_paused({:call, from}, {:authorize_command, command_class}, %ControllerState{} = data) do
    {:keep_state, data, [{:reply, from, authorize_paused_command(command_class, data)}]}
  end

  def auto_paused({:call, from}, :reset, %ControllerState{} = data) do
    case terminate_active_run(data) do
      {:ok, next_data} ->
        {:next_state, :manual_idle, next_data, [{:reply, from, :ok}]}

      {:error, :sequence_run_not_active} ->
        {:next_state, :manual_idle, clear_active_runtime(data), [{:reply, from, :ok}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def auto_paused(
        {:call, from},
        {:start_run, _sequence_id, _sequence_module, _runtime_state, _policy},
        data
      ) do
    {:keep_state, data, [{:reply, from, {:error, active_reason(data)}}]}
  end

  def auto_paused(
        :info,
        {:sequence_progress, pid, :resumed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = update_active_snapshot(data, snapshot)
    {:next_state, :auto_running, next_data, dispatch_ops([{:sequence_run_resumed, snapshot}])}
  end

  def auto_paused(
        :info,
        {:sequence_progress, pid, :completed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_completed, snapshot}
     ])}
  end

  def auto_paused(
        :info,
        {:sequence_progress, pid, :aborted, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_aborted, snapshot}
     ])}
  end

  def auto_paused(
        :info,
        {:sequence_progress, pid, :failed, snapshot},
        %ControllerState{active: %{pid: pid}} = data
      ) do
    next_data = clear_active_runtime(data)

    {:next_state, :auto_idle, next_data,
     dispatch_ops([
       release_control_operation(data),
       {:sequence_run_failed, snapshot}
     ])}
  end

  def auto_paused(
        :info,
        {:DOWN, ref, :process, pid, reason},
        %ControllerState{active: %{pid: pid, monitor_ref: ref} = active} = data
      ) do
    next_data = clear_active_runtime(data)

    case normalize_exit_reason(reason) do
      :normal ->
        move_to_held(data, [{:sequence_runner_exited, :normal}])

      :shutdown ->
        move_to_held(data, [{:sequence_runner_exited, :shutdown}])

      unexpected ->
        {:next_state, :auto_idle, next_data,
         dispatch_ops([
           release_control_operation(data),
           {:sequence_run_failed, failure_snapshot(active, {:sequence_runner_exited, unexpected})}
         ])}
    end
  end

  def auto_paused(_event_type, _event_content, _data) do
    :keep_state_and_data
  end

  def auto_held(:internal, {:dispatch, operation}, data) do
    dispatch_operation(operation)
    {:keep_state, data}
  end

  def auto_held({:call, from}, {:set_control_mode, _control_mode}, data) do
    {:keep_state, data, [{:reply, from, {:error, active_reason(data)}}]}
  end

  def auto_held({:call, from}, :cancel_run, %ControllerState{} = data) do
    do_abort_held_run(from, data)
  end

  def auto_held({:call, from}, :acknowledge_run, %ControllerState{} = data) do
    do_acknowledge_held_run(from, data)
  end

  def auto_held({:call, from}, :pause_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_running}}]}
  end

  def auto_held({:call, from}, :request_manual_takeover, %ControllerState{} = data) do
    do_request_manual_takeover(from, data)
  end

  def auto_held({:call, from}, :resume_run, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :sequence_run_not_paused}}]}
  end

  def auto_held({:call, from}, {:resume_held_run, runtime_state}, %ControllerState{} = data) do
    do_resume_held_run(from, data, runtime_state)
  end

  def auto_held({:call, from}, {:hold_run, reasons}, %ControllerState{} = data) do
    case refresh_held_operations(data, reasons) do
      {:ok, operations, next_data} ->
        {:keep_state, next_data, [{:reply, from, {:ok, operations}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  def auto_held({:call, from}, {:authorize_command, command_class}, %ControllerState{} = data) do
    {:keep_state, data, [{:reply, from, authorize_held_command(command_class, data)}]}
  end

  def auto_held({:call, from}, :reset, %ControllerState{} = data) do
    {:next_state, :manual_idle, clear_active_runtime(data), [{:reply, from, :ok}]}
  end

  def auto_held(
        {:call, from},
        {:start_run, _sequence_id, _sequence_module, _runtime_state, _policy},
        data
      ) do
    {:keep_state, data, [{:reply, from, {:error, active_reason(data)}}]}
  end

  def auto_held(_event_type, _event_content, _data) do
    :keep_state_and_data
  end

  defp do_cancel_run(from, %ControllerState{} = data) do
    case cancel_operations(data) do
      {:ok, operations, next_data} ->
        {:keep_state, next_data, [{:reply, from, {:ok, operations}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp do_pause_run(from, %ControllerState{} = data) do
    case pause_operations(data) do
      {:ok, operations, next_data} ->
        {:keep_state, next_data, [{:reply, from, {:ok, operations}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp do_request_manual_takeover(from, %ControllerState{} = data) do
    case request_manual_takeover_operations(data) do
      {:ok, operations, next_data} ->
        {:keep_state, next_data, [{:reply, from, {:ok, operations}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp do_resume_run(from, %ControllerState{} = data) do
    case resume_operations(data) do
      {:ok, operations, next_data} ->
        {:keep_state, next_data, [{:reply, from, {:ok, operations}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp do_resume_held_run(from, %ControllerState{} = data, %RuntimeState{} = runtime_state) do
    case resume_held_operations(data, runtime_state) do
      {:ok, operations, next_data} ->
        {:next_state, :auto_starting, next_data,
         [{:reply, from, {:ok, operations}}, {:next_event, :internal, :begin_active_run}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp do_hold_run(from, %ControllerState{} = data, reasons) when is_list(reasons) do
    case hold_operations(data, reasons) do
      {:ok, operations, next_data} ->
        {:next_state, :auto_held, next_data, [{:reply, from, {:ok, operations}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp do_abort_held_run(from, %ControllerState{} = data) do
    case abort_held_operations(data) do
      {:ok, operations, next_data} ->
        {:next_state, :auto_idle, next_data, [{:reply, from, {:ok, operations}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp do_acknowledge_held_run(from, %ControllerState{} = data) do
    case acknowledge_held_operations(data) do
      {:ok, operations, next_data} ->
        {:next_state, :auto_idle, next_data, [{:reply, from, {:ok, operations}}]}

      {:error, reason} ->
        {:keep_state_and_data, [{:reply, from, {:error, reason}}]}
    end
  end

  defp cancel_operations(%ControllerState{active: nil}) do
    {:error, :sequence_run_not_active}
  end

  defp cancel_operations(%ControllerState{active: %{abort_requested?: true}} = data) do
    {:ok, [], data}
  end

  defp cancel_operations(
         %ControllerState{
           active: %{topology_scope: topology_scope, run_id: run_id} = active
         } = data
       ) do
    requested_at = DateTime.utc_now()

    case SequenceRuntime.request_abort(topology_scope,
           requested_by: :operator,
           requested_at: requested_at
         ) do
      :ok ->
        {:ok,
         [
           {:sequence_abort_requested,
            %{
              run_id: run_id,
              requested_by: :operator,
              requested_at: requested_at,
              admitted_at: requested_at
            }}
         ], put_active(data, %{active | abort_requested?: true})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pause_operations(%ControllerState{active: nil}) do
    {:error, :sequence_run_not_active}
  end

  defp pause_operations(%ControllerState{active: %{pause_requested?: true}} = data) do
    {:ok, [], data}
  end

  defp pause_operations(
         %ControllerState{
           active: %{topology_scope: topology_scope, run_id: run_id} = active
         } = data
       ) do
    requested_at = DateTime.utc_now()

    case SequenceRuntime.request_pause(topology_scope,
           requested_by: :operator,
           requested_at: requested_at
         ) do
      :ok ->
        {:ok,
         [
           {:sequence_pause_requested,
            %{
              run_id: run_id,
              requested_by: :operator,
              requested_at: requested_at,
              admitted_at: requested_at
            }}
         ], put_active(data, %{active | pause_requested?: true})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_manual_takeover_operations(%ControllerState{active: nil}) do
    {:error, :sequence_run_not_active}
  end

  defp request_manual_takeover_operations(
         %ControllerState{
           active: %{run_id: run_id, takeover_requested?: false},
           held_snapshot: snapshot
         } = data
       )
       when is_map(snapshot) do
    requested_at = DateTime.utc_now()
    aborted_snapshot = held_manual_takeover_snapshot(snapshot)

    {:ok,
     [
       manual_takeover_requested_operation(run_id, requested_at),
       release_control_operation(:manual),
       {:sequence_run_aborted, aborted_snapshot}
     ], clear_active_runtime(data)}
  end

  defp request_manual_takeover_operations(
         %ControllerState{active: %{takeover_requested?: true}} = data
       ) do
    {:ok, [], data}
  end

  defp request_manual_takeover_operations(%ControllerState{active: %{run_id: run_id}} = data) do
    requested_at = DateTime.utc_now()

    case cancel_operations(data) do
      {:ok, operations, next_data} ->
        next_active = Map.fetch!(next_data, :active)

        {:ok, [manual_takeover_requested_operation(run_id, requested_at) | operations],
         put_active(next_data, %{next_active | takeover_requested?: true})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_operations(%ControllerState{active: nil}) do
    {:error, :sequence_run_not_active}
  end

  defp resume_operations(%ControllerState{active: %{takeover_requested?: true}}) do
    {:error, :manual_takeover_pending}
  end

  defp resume_operations(
         %ControllerState{
           active: %{topology_scope: topology_scope, pause_requested?: pause_requested?} = active
         } = data
       ) do
    case SequenceRuntime.request_resume(topology_scope, requested_by: :operator) do
      :ok ->
        {:ok, [], put_active(data, %{active | pause_requested?: pause_requested?})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_held_operations(%ControllerState{active: nil}, _runtime_state) do
    {:error, :sequence_run_not_active}
  end

  defp resume_held_operations(
         %ControllerState{active: %{takeover_requested?: true}},
         _runtime_state
       ) do
    {:error, :manual_takeover_pending}
  end

  defp resume_held_operations(%ControllerState{held_snapshot: nil}, _runtime_state) do
    {:error, :sequence_run_not_resumable}
  end

  defp resume_held_operations(
         %ControllerState{
           active:
             %{
               run_id: run_id,
               sequence_id: sequence_id,
               sequence_module: sequence_module
             } = active,
           held_snapshot: held_snapshot
         } = data,
         %RuntimeState{} = runtime_state
       ) do
    with :ok <- ensure_runtime_running(runtime_state),
         :ok <- ensure_runtime_trusted(runtime_state),
         :ok <- ensure_resume_snapshot(held_snapshot),
         :ok <- ensure_generation_match(runtime_state, held_snapshot),
         {:ok, topology_scope} <- topology_scope(runtime_state),
         {:ok, %Ogol.Sequence.Model{sequence: sequence} = model} <-
           fetch_sequence_model(sequence_module),
         :ok <- ensure_sequence_matches_runtime(sequence, runtime_state),
         {:ok, pid} <-
           SequenceRuntime.start_run(
             topology_scope,
             run_id: run_id,
             sequence_id: sequence_id,
             sequence_module: sequence_module,
             sequence_model: model,
             policy: Map.get(held_snapshot, :policy, active.policy),
             run_generation: Map.get(held_snapshot, :run_generation),
             deployment_id: runtime_state.deployment_id,
             topology_module: runtime_state.active_topology_module,
             owner: self(),
             resume_snapshot: held_snapshot
           ) do
      monitor_ref = Process.monitor(pid)

      next_active = %{
        active
        | pid: pid,
          monitor_ref: monitor_ref,
          topology_scope: topology_scope,
          topology_module: runtime_state.active_topology_module,
          policy: Map.get(held_snapshot, :policy, active.policy),
          run_generation: Map.get(held_snapshot, :run_generation),
          pause_requested?: false,
          abort_requested?: false,
          deployment_id: runtime_state.deployment_id,
          last_snapshot: held_snapshot
      }

      {:ok, [],
       data
       |> put_active(next_active)
       |> clear_held_snapshot()}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp hold_operations(%ControllerState{active: nil}, _reasons) do
    {:error, :sequence_run_not_active}
  end

  defp hold_operations(
         %ControllerState{
           active: %{topology_scope: topology_scope} = active
         } = data,
         reasons
       ) do
    with {:ok, snapshot} <- snapshot_for_hold(active),
         :ok <- stop_active_run(topology_scope) do
      held_snapshot = hold_snapshot(snapshot, reasons)

      {:ok, [{:sequence_run_held, held_snapshot}],
       data
       |> clear_active_monitor()
       |> put_active(%{active | pid: nil, monitor_ref: nil})
       |> put_held_snapshot(held_snapshot)}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp abort_held_operations(%ControllerState{active: nil}) do
    {:error, :sequence_run_not_active}
  end

  defp abort_held_operations(%ControllerState{held_snapshot: nil}) do
    {:error, :sequence_run_not_active}
  end

  defp abort_held_operations(%ControllerState{held_snapshot: snapshot} = data) do
    finished_at = System.system_time(:millisecond)

    aborted_snapshot =
      snapshot
      |> Map.put(:finished_at, finished_at)
      |> Map.put(:last_error, nil)

    {:ok,
     [
       release_control_operation(data),
       {:sequence_run_aborted, aborted_snapshot}
     ], clear_active_runtime(data)}
  end

  defp acknowledge_held_operations(%ControllerState{active: nil}) do
    {:error, :sequence_run_not_active}
  end

  defp acknowledge_held_operations(%ControllerState{held_snapshot: nil}) do
    {:error, :sequence_run_not_held}
  end

  defp acknowledge_held_operations(%ControllerState{} = data) do
    {:ok,
     [
       release_control_operation(data),
       :clear_sequence_run_result
     ], clear_active_runtime(data)}
  end

  defp refresh_held_operations(%ControllerState{active: nil}, _reasons) do
    {:error, :sequence_run_not_active}
  end

  defp refresh_held_operations(
         %ControllerState{active: active} = data,
         reasons
       )
       when is_list(reasons) do
    held_snapshot =
      active
      |> active_snapshot()
      |> hold_snapshot(reasons)

    {:ok, [{:sequence_run_held, held_snapshot}],
     data
     |> put_active(%{active | last_snapshot: held_snapshot})
     |> put_held_snapshot(held_snapshot)}
  end

  defp terminate_active_run(%ControllerState{active: nil}) do
    {:error, :sequence_run_not_active}
  end

  defp terminate_active_run(%ControllerState{active: %{topology_scope: topology_scope}} = data) do
    case stop_active_run(topology_scope) do
      :ok -> {:ok, clear_active_runtime(data)}
      {:error, :sequence_run_not_active} -> {:ok, clear_active_runtime(data)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop_active_run(topology_scope) do
    case SequenceRuntime.stop_run(topology_scope) do
      :ok -> :ok
      {:error, :sequence_run_not_active} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_runtime_running(%RuntimeState{
         observed: observed,
         topology_generation: topology_generation,
         deployment_id: deployment_id,
         active_topology_module: active_topology_module
       })
       when observed in [{:running, :simulation}, {:running, :live}] and
              is_binary(topology_generation) and is_binary(deployment_id) and
              is_atom(active_topology_module),
       do: :ok

  defp ensure_runtime_running(_runtime_state), do: {:error, :topology_not_running}

  defp ensure_runtime_trusted(%RuntimeState{trust_state: :trusted}), do: :ok
  defp ensure_runtime_trusted(_runtime_state), do: {:error, :runtime_not_trusted}

  defp runtime_generation(%RuntimeState{topology_generation: topology_generation})
       when is_binary(topology_generation),
       do: {:ok, topology_generation}

  defp runtime_generation(%RuntimeState{deployment_id: deployment_id})
       when is_binary(deployment_id),
       do: {:ok, deployment_id}

  defp runtime_generation(_runtime_state), do: {:error, :missing_topology_generation}

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

  defp ensure_generation_match(%RuntimeState{} = runtime_state, snapshot) when is_map(snapshot) do
    case {runtime_generation(runtime_state), Map.get(snapshot, :run_generation)} do
      {{:ok, generation}, generation} when is_binary(generation) -> :ok
      _other -> {:error, :topology_generation_changed}
    end
  end

  defp ensure_resume_snapshot(%{resumable?: true, resume_from_boundary: boundary} = snapshot)
       when is_binary(boundary) do
    case Map.get(snapshot, :resume_stack) do
      resume_stack when is_list(resume_stack) -> :ok
      _other -> {:error, :sequence_run_not_resumable}
    end
  end

  defp ensure_resume_snapshot(_snapshot), do: {:error, :sequence_run_not_resumable}

  defp failure_snapshot(active, reason) when is_map(active) do
    active
    |> active_snapshot()
    |> RuntimeFaultPolicy.external_runtime_failure(reason)
  end

  defp hold_snapshot(snapshot, reasons) when is_map(snapshot) and is_list(reasons) do
    RuntimeFaultPolicy.external_runtime_hold(snapshot, reasons)
  end

  defp move_to_held(%ControllerState{} = data, reasons) when is_list(reasons) do
    snapshot =
      data.active
      |> active_snapshot()
      |> hold_snapshot(reasons)

    if manual_takeover_requested?(data) do
      aborted_snapshot = held_manual_takeover_snapshot(snapshot)

      {:next_state, :manual_idle, clear_active_runtime(data),
       dispatch_ops([
         release_control_operation(:manual),
         {:sequence_run_aborted, aborted_snapshot}
       ])}
    else
      next_data =
        data
        |> clear_active_monitor()
        |> put_active(%{data.active | pid: nil, monitor_ref: nil, last_snapshot: snapshot})
        |> put_held_snapshot(snapshot)

      {:next_state, :auto_held, next_data, dispatch_ops([{:sequence_run_held, snapshot}])}
    end
  end

  defp snapshot_for_hold(%{topology_scope: topology_scope} = active) do
    case SequenceRuntime.snapshot(topology_scope) do
      {:ok, snapshot} ->
        {:ok, snapshot}

      {:error, _reason} ->
        {:ok, active_snapshot(active)}
    end
  end

  defp active_snapshot(%{last_snapshot: snapshot}) when is_map(snapshot), do: snapshot

  defp active_snapshot(active) when is_map(active) do
    %{
      sequence_id: active.sequence_id,
      sequence_module: active.sequence_module,
      run_id: active.run_id,
      policy: active.policy,
      cycle_count: 0,
      resumable?: false,
      resume_from_boundary: nil,
      resume_blockers: [],
      run_generation: active.run_generation,
      fault_source: nil,
      fault_recoverability: nil,
      fault_scope: nil,
      deployment_id: active.deployment_id,
      topology_module: active.topology_module,
      current_procedure: nil,
      current_step_id: nil,
      current_step_label: nil,
      started_at: nil,
      finished_at: nil,
      last_error: nil
    }
  end

  defp clear_active_runtime(%ControllerState{} = data) do
    %ControllerState{} = next_data = clear_active_monitor(data)
    %ControllerState{next_data | owner: :manual_operator, active: nil, held_snapshot: nil}
  end

  defp clear_active_monitor(%ControllerState{} = data) do
    case data.active do
      %{monitor_ref: monitor_ref} when is_reference(monitor_ref) ->
        Process.demonitor(monitor_ref, [:flush])

      _other ->
        :ok
    end

    data
  end

  defp put_active(%ControllerState{} = data, active) when is_map(active) do
    %ControllerState{data | active: active}
  end

  defp put_held_snapshot(%ControllerState{} = data, snapshot) when is_map(snapshot) do
    %ControllerState{data | held_snapshot: snapshot}
  end

  defp clear_held_snapshot(%ControllerState{} = data) do
    %ControllerState{data | held_snapshot: nil}
  end

  defp clear_pause_request(%ControllerState{active: %{pause_requested?: _value} = active} = data) do
    put_active(data, %{active | pause_requested?: false})
  end

  defp clear_pause_request(%ControllerState{} = data), do: data

  defp manual_takeover_requested_operation(run_id, requested_at) do
    {:manual_takeover_requested,
     %{
       run_id: run_id,
       requested_by: :operator,
       requested_at: requested_at,
       admitted_at: requested_at
     }}
  end

  defp held_manual_takeover_snapshot(snapshot) when is_map(snapshot) do
    snapshot
    |> Map.put(:finished_at, System.system_time(:millisecond))
    |> Map.put(:last_error, {:manual_takeover, :operator})
  end

  defp release_control_operation(%ControllerState{} = data) do
    if manual_takeover_requested?(data) do
      release_control_operation(:manual)
    else
      release_control_operation(:auto)
    end
  end

  defp release_control_operation(:manual), do: {:sync_auto_control, :manual, :manual_operator}
  defp release_control_operation(:auto), do: {:sync_auto_control, :auto, :manual_operator}

  defp manual_takeover_requested?(%ControllerState{active: %{takeover_requested?: true}}),
    do: true

  defp manual_takeover_requested?(_data), do: false

  defp update_active_snapshot(%ControllerState{active: active} = data, snapshot)
       when is_map(active) and is_map(snapshot) do
    put_active(data, Map.put(active, :last_snapshot, snapshot))
  end

  defp update_active_snapshot(%ControllerState{} = data, _snapshot), do: data

  defp active_reason(%ControllerState{active: %{sequence_id: sequence_id}}),
    do: {:sequence_run_active, sequence_id}

  defp active_reason(_data), do: :sequence_run_active

  defp authorize_manual_command(:read_only), do: :ok
  defp authorize_manual_command(:normal_operator), do: :ok
  defp authorize_manual_command({:sequence_run, _run_id}), do: {:error, :sequence_run_not_active}
  defp authorize_manual_command(_command_class), do: {:error, :unsupported_command_class}

  defp authorize_auto_idle_command(:read_only), do: :ok
  defp authorize_auto_idle_command(:normal_operator), do: {:error, :auto_mode_armed}

  defp authorize_auto_idle_command({:sequence_run, _run_id}),
    do: {:error, :sequence_run_not_active}

  defp authorize_auto_idle_command(_command_class), do: {:error, :unsupported_command_class}

  defp authorize_active_command(:read_only, _data), do: :ok

  defp authorize_active_command(:normal_operator, %ControllerState{active: %{run_id: run_id}}),
    do: {:error, {:owned_by_sequence_run, run_id}}

  defp authorize_active_command(
         {:sequence_run, run_id},
         %ControllerState{active: %{run_id: run_id}}
       ),
       do: :ok

  defp authorize_active_command(
         {:sequence_run, _run_id},
         %ControllerState{active: %{run_id: active_run_id}}
       ),
       do: {:error, {:owned_by_sequence_run, active_run_id}}

  defp authorize_active_command(_command_class, _data), do: {:error, :unsupported_command_class}

  defp authorize_paused_command(:read_only, _data), do: :ok

  defp authorize_paused_command(:normal_operator, %ControllerState{active: %{run_id: run_id}}),
    do: {:error, {:owned_by_sequence_run, run_id}}

  defp authorize_paused_command({:sequence_run, _run_id}, _data),
    do: {:error, :sequence_run_paused}

  defp authorize_paused_command(_command_class, _data), do: {:error, :unsupported_command_class}

  defp authorize_held_command(:read_only, _data), do: :ok

  defp authorize_held_command(:normal_operator, %ControllerState{active: %{run_id: run_id}}),
    do: {:error, {:owned_by_sequence_run, run_id}}

  defp authorize_held_command({:sequence_run, _run_id}, _data), do: {:error, :sequence_run_held}

  defp authorize_held_command(_command_class, _data), do: {:error, :unsupported_command_class}

  defp dispatch_ops(operations) when is_list(operations) do
    Enum.map(operations, fn operation ->
      {:next_event, :internal, {:dispatch, operation}}
    end)
  end

  defp dispatch_operation(operation) do
    Kernel.send(Ogol.Session, {:auto_controller_operation, operation})
    :ok
  end

  defp next_run_id do
    "sr#{System.unique_integer([:positive])}"
  end

  defp normalize_exit_reason({:shutdown, reason}), do: normalize_exit_reason(reason)
  defp normalize_exit_reason(:normal), do: :normal
  defp normalize_exit_reason(:shutdown), do: :shutdown
  defp normalize_exit_reason(reason), do: reason
end
