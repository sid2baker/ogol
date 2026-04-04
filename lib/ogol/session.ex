defmodule Ogol.Session do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.Surface.Defaults, as: SurfaceDefaults
  alias Ogol.Hardware
  alias Ogol.Hardware.Source, as: HardwareSource
  alias Ogol.Runtime
  alias Ogol.Runtime.{Bus, CommandGateway, EventLog, SnapshotStore}
  alias Ogol.Runtime.Hardware.Context, as: HardwareContext
  alias Ogol.Runtime.Hardware.Diff, as: HardwareDiff
  alias Ogol.Runtime.Hardware.Gateway, as: HardwareGateway
  alias Ogol.Simulator.Config.Source, as: SimulatorConfigSource
  alias Ogol.Session.{RevisionFile, Revisions, RuntimeOwner, SequenceOwner, State, Workspace}
  alias Ogol.Studio.Examples

  @dispatch_timeout 15_000
  @type kind :: State.kind()
  @type client_id :: String.t()

  defmodule ServerState do
    @moduledoc false

    @type t :: %__MODULE__{
            session_state: State.t(),
            next_client_number: pos_integer(),
            client_ids: %{optional(pid()) => Ogol.Session.client_id()},
            client_monitors: %{optional(reference()) => pid()}
          }

    defstruct session_state: State.new(),
              next_client_number: 1,
              client_ids: %{},
              client_monitors: %{}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def dispatch(operation, timeout \\ @dispatch_timeout) do
    GenServer.call(__MODULE__, {:dispatch, operation}, timeout)
  end

  @spec register_client(pid()) :: {State.t(), client_id()}
  def register_client(client_pid) when is_pid(client_pid) do
    GenServer.call(__MODULE__, {:register_client, client_pid}, @dispatch_timeout)
  end

  @spec get_state() :: State.t()
  def get_state do
    GenServer.call(__MODULE__, :get_state, @dispatch_timeout)
  end

  def reset_machines, do: dispatch({:reset_kind, :machine})

  def replace_machines(drafts) when is_list(drafts),
    do: dispatch({:replace_entries, :machine, drafts})

  def list_machines, do: list_entries(:machine)
  def fetch_machine(id) when is_binary(id), do: fetch(:machine, id)
  def create_machine(id \\ nil), do: dispatch({:create_entry, :machine, normalize_create_id(id)})

  def save_machine_source(id, source, model, sync_state, sync_diagnostics) do
    dispatch({:save_source, :machine, id, source, model, sync_state, sync_diagnostics})
  end

  def reset_topologies, do: dispatch({:reset_kind, :topology})

  def replace_topologies(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :topology, drafts})
  end

  def list_topologies, do: list_entries(:topology)
  def fetch_topology(id) when is_binary(id), do: fetch(:topology, id)
  def topology, do: list_topologies() |> List.first()

  def create_topology(id \\ nil),
    do: dispatch({:create_entry, :topology, normalize_create_id(id)})

  def save_topology_source(id, source, model, sync_state, sync_diagnostics) do
    dispatch({:save_source, :topology, id, source, model, sync_state, sync_diagnostics})
  end

  def reset_sequences, do: dispatch({:reset_kind, :sequence})

  def replace_sequences(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :sequence, drafts})
  end

  def list_sequences, do: list_entries(:sequence)
  def fetch_sequence(id) when is_binary(id), do: fetch(:sequence, id)

  def create_sequence(id \\ nil),
    do: dispatch({:create_entry, :sequence, normalize_create_id(id)})

  def save_sequence_source(id, source, model, sync_state, sync_diagnostics) do
    dispatch({:save_source, :sequence, id, source, model, sync_state, sync_diagnostics})
  end

  def reset_hardware, do: dispatch({:reset_kind, :hardware})

  def replace_hardware(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :hardware, drafts})
  end

  def list_hardware, do: list_entries(:hardware)
  def fetch_hardware(id) when is_binary(id), do: fetch(:hardware, id)

  def fetch_hardware(adapter) when is_atom(adapter),
    do: fetch_hardware(config_id(adapter))

  def fetch_hardware_model(id) when is_binary(id),
    do: State.hardware_model(get_state(), id)

  def fetch_hardware_model(adapter) when is_atom(adapter),
    do: fetch_hardware_model(config_id(adapter))

  def create_hardware(id \\ nil),
    do: dispatch({:create_entry, :hardware, normalize_hardware_id(id)})

  def save_hardware_source(id, source, model, sync_state, sync_diagnostics)
      when is_binary(id) do
    dispatch({:save_source, :hardware, id, source, model, sync_state, sync_diagnostics})
  end

  def put_hardware(config) when is_struct(config) do
    put_hardware(config_id(config), config)
  end

  def put_hardware(adapter, config) when is_atom(adapter) and is_struct(config) do
    put_hardware(config_id(adapter), config)
  end

  def put_hardware(id, config) when is_binary(id) and is_struct(config) do
    draft = %Workspace.SourceDraft{
      id: id,
      source: HardwareSource.to_source(config),
      model: config,
      sync_state: :synced,
      sync_diagnostics: []
    }

    replace_hardware([draft])
    draft
  end

  def reset_simulator_configs, do: dispatch({:reset_kind, :simulator_config})

  def replace_simulator_configs(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :simulator_config, drafts})
  end

  def list_simulator_configs, do: list_entries(:simulator_config)
  def fetch_simulator_config(id) when is_binary(id), do: fetch(:simulator_config, id)

  def fetch_simulator_config(adapter) when is_atom(adapter),
    do: fetch_simulator_config(config_id(adapter))

  def fetch_simulator_config_model(id) when is_binary(id),
    do: State.simulator_config_model(get_state(), id)

  def fetch_simulator_config_model(adapter) when is_atom(adapter),
    do: fetch_simulator_config_model(config_id(adapter))

  def create_simulator_config(id \\ nil),
    do: dispatch({:create_entry, :simulator_config, normalize_hardware_id(id)})

  def save_simulator_config_source(id, source, model, sync_state, sync_diagnostics)
      when is_binary(id) do
    dispatch({:save_source, :simulator_config, id, source, model, sync_state, sync_diagnostics})
  end

  def put_simulator_config(%{} = config) do
    put_simulator_config(simulator_config_id(config), config)
  end

  def put_simulator_config(adapter, config) when is_atom(adapter) and is_map(config) do
    put_simulator_config(config_id(adapter), config)
  end

  def put_simulator_config(id, config) when is_binary(id) and is_map(config) do
    draft = %Workspace.SourceDraft{
      id: id,
      source: SimulatorConfigSource.to_source(config),
      model: config,
      sync_state: :synced,
      sync_diagnostics: []
    }

    replace_simulator_configs([draft])
    draft
  end

  def reset_hmi_surfaces do
    replace_hmi_surfaces(SurfaceDefaults.drafts_from_workspace())
  end

  def replace_hmi_surfaces(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :hmi_surface, drafts})
  end

  def list_hmi_surfaces, do: list_entries(:hmi_surface)
  def fetch_hmi_surface(id) when is_binary(id), do: fetch(:hmi_surface, id)

  def save_hmi_surface_source(id, source, source_module, model, sync_state, sync_diagnostics)
      when is_binary(id) and is_binary(source) and is_atom(source_module) do
    dispatch(
      {:save_hmi_surface_source, id, source, source_module, model, sync_state, sync_diagnostics}
    )
  end

  def list_kind(kind) when is_atom(kind), do: State.list_kind(get_state(), kind)

  def fetch(kind, id) when is_atom(kind) and is_binary(id), do: State.fetch(get_state(), kind, id)

  def loaded_inventory do
    case loaded_revision() do
      %Workspace.LoadedRevision{inventory: inventory} -> inventory
      nil -> []
    end
  end

  def loaded_revision, do: State.loaded_revision(get_state())

  def put_loaded_revision(app_id, revision, inventory) when is_list(inventory) do
    dispatch({:put_loaded_revision, app_id, revision, inventory})
  end

  def set_loaded_revision_id(revision) when is_binary(revision) or is_nil(revision) do
    dispatch({:set_loaded_revision_id, revision})
  end

  def reset_loaded_revision do
    dispatch(:reset_loaded_revision)
  end

  def subscribe(:workspace), do: Bus.subscribe(Bus.workspace_topic())
  def subscribe(:events), do: Bus.subscribe(Bus.events_topic())
  def subscribe(:overview), do: Bus.subscribe(Bus.overview_topic())

  def subscribe({:machine, machine_id}) when is_binary(machine_id),
    do: Bus.subscribe(Bus.machine_topic(machine_id))

  def list_revisions(app_id \\ nil), do: Revisions.list_revisions(app_id)
  def fetch_revision(app_id, revision_id), do: Revisions.fetch_revision(app_id, revision_id)
  def save_current_revision(opts \\ []), do: Revisions.save_current(opts)
  def deploy_current_revision(opts \\ []), do: Revisions.deploy_current(opts)
  def reset_revisions, do: Revisions.reset()

  def export_current_revision(opts \\ []), do: RevisionFile.export_current(opts)
  def import_revision_source(source), do: RevisionFile.import(source)
  def load_revision_source(source, opts \\ []), do: RevisionFile.load_into_workspace(source, opts)
  def list_examples, do: Examples.list()
  def load_example(id, opts \\ []) when is_binary(id), do: Examples.load_into_workspace(id, opts)

  def set_desired_runtime(desired)
      when desired in [:stopped, {:running, :simulation}, {:running, :live}] do
    dispatch({:set_desired_runtime, desired})
  end

  def start_sequence_run(sequence_id) when is_binary(sequence_id) do
    dispatch({:start_sequence_run, sequence_id})
  end

  def cancel_sequence_run do
    dispatch(:cancel_sequence_run)
  end

  def reset_runtime do
    _ = SequenceOwner.reset()

    case RuntimeOwner.reset() do
      :ok ->
        case Runtime.reset() do
          :ok -> dispatch(:reset_runtime_state)
          other -> other
        end

      other ->
        other
    end
  end

  def runtime_state do
    get_state()
    |> State.runtime()
  end

  def sequence_run_state do
    get_state()
    |> State.sequence_run()
  end

  def runtime_realized? do
    get_state()
    |> State.runtime_realized?()
  end

  def runtime_dirty? do
    get_state()
    |> State.runtime_dirty?()
  end

  def runtime_status(kind, id) do
    case State.runtime_artifact_status(get_state(), kind, id) do
      nil -> {:error, :not_found}
      status -> {:ok, status}
    end
  end

  def runtime_current(kind, id) do
    case State.runtime_current(get_state(), kind, id) do
      nil -> {:error, :not_found}
      module -> {:ok, module}
    end
  end

  def recent_events(limit), do: EventLog.recent(limit)
  def list_runtime_machines, do: SnapshotStore.list_machines()

  def invoke_machine(machine_id, name, data \\ %{}, opts \\ []),
    do: CommandGateway.invoke(machine_id, name, data, opts)

  def build_hardware_context(ethercat, events, saved_configs, opts \\ []) do
    HardwareContext.build(ethercat, events, saved_configs, opts)
  end

  def compare_hardware_draft_to_live(draft_form, live_preview) do
    HardwareDiff.compare_draft_to_live(draft_form, live_preview)
  end

  defdelegate scan_ethercat_master_form(form), to: HardwareGateway
  defdelegate start_ethercat_master(config_input), to: HardwareGateway
  defdelegate stop_ethercat_master(), to: HardwareGateway
  defdelegate start_simulation_config(config_input), to: HardwareGateway
  defdelegate stop_simulation(config_id), to: HardwareGateway
  defdelegate capture_ethercat_hardware(params), to: HardwareGateway
  defdelegate preview_ethercat_hardware_form(form), to: HardwareGateway
  defdelegate preview_ethercat_simulator_config(form), to: HardwareGateway
  defdelegate promote_candidate_config(config), to: HardwareGateway
  defdelegate arm_candidate_release(), to: HardwareGateway
  defdelegate rollback_armed_release(version), to: HardwareGateway
  defdelegate preview_ethercat_hardware(params), to: HardwareGateway
  defdelegate configure_ethercat_slave(slave_name, params), to: HardwareGateway
  defdelegate activate_ethercat(), to: HardwareGateway
  defdelegate deactivate_ethercat(state_target), to: HardwareGateway
  defdelegate capture_support_snapshot(params), to: HardwareGateway
  defdelegate ethercat_session(), to: HardwareGateway
  defdelegate current_candidate_release(), to: HardwareGateway
  defdelegate current_armed_release(), to: HardwareGateway
  defdelegate release_history(), to: HardwareGateway
  defdelegate list_support_snapshots(), to: HardwareGateway
  defdelegate default_ethercat_hardware_form(), to: HardwareGateway
  defdelegate default_ethercat_simulator_form(), to: HardwareGateway

  defp config_id(config) when is_struct(config), do: Hardware.artifact_id(config)
  defp config_id(adapter) when is_atom(adapter), do: Hardware.artifact_id(adapter)

  defp simulator_config_id(config) when is_map(config),
    do: SimulatorConfigSource.artifact_id(config)

  defp normalize_hardware_id(nil), do: :auto
  defp normalize_hardware_id(id) when is_binary(id), do: id
  defp normalize_hardware_id(adapter) when is_atom(adapter), do: config_id(adapter)
  defdelegate candidate_vs_armed_diff(), to: HardwareGateway
  defdelegate available_raw_interfaces(), to: HardwareGateway
  defdelegate get_support_snapshot(snapshot_id), to: HardwareGateway
  defdelegate available_simulation_drivers(), to: HardwareGateway
  defdelegate ethercat_hardware_form_from_config(config), to: HardwareGateway
  defdelegate ethercat_simulator_form_from_config(config), to: HardwareGateway

  @impl true
  def init(_opts) do
    {:ok, %ServerState{}}
  end

  @impl true
  def handle_call({:register_client, client_pid}, _from, %ServerState{} = state) do
    case Map.fetch(state.client_ids, client_pid) do
      {:ok, client_id} ->
        {:reply, {state.session_state, client_id}, state}

      :error ->
        client_id = next_client_id(state)
        monitor_ref = Process.monitor(client_pid)

        next_state = %ServerState{
          state
          | next_client_number: state.next_client_number + 1,
            client_ids: Map.put(state.client_ids, client_pid, client_id),
            client_monitors: Map.put(state.client_monitors, monitor_ref, client_pid)
        }

        {:reply, {state.session_state, client_id}, next_state}
    end
  end

  def handle_call(:get_state, _from, %ServerState{} = state) do
    {:reply, state.session_state, state}
  end

  def handle_call({:dispatch, operation}, _from, %ServerState{} = state) do
    {:reply, reply, next_state} = execute_dispatch(state, operation)
    {:reply, reply, next_state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, client_pid, _reason}, %ServerState{} = state) do
    case Map.pop(state.client_monitors, monitor_ref) do
      {nil, _client_monitors} ->
        {:noreply, state}

      {_pid, client_monitors} ->
        {:noreply,
         %ServerState{
           state
           | client_ids: Map.delete(state.client_ids, client_pid),
             client_monitors: client_monitors
         }}
    end
  end

  defp list_entries(kind), do: State.list_entries(get_state(), kind)

  defp normalize_create_id(nil), do: :auto
  defp normalize_create_id(id), do: id

  defp next_client_id(%ServerState{} = state), do: "c#{state.next_client_number}"

  defp execute_dispatch(%ServerState{} = state, operation) do
    case State.apply_operation(state.session_state, operation) do
      {:ok, next_session_state, reply, accepted_operations, actions} ->
        next_state =
          %ServerState{state | session_state: next_session_state}
          |> broadcast_operations(accepted_operations)
          |> handle_actions(actions)

        {:reply, reply, next_state}

      :error ->
        {:reply, :error, state}
    end
  end

  defp broadcast_operations(%ServerState{} = state, []), do: state

  defp broadcast_operations(%ServerState{} = state, operations) when is_list(operations) do
    Bus.broadcast(Bus.workspace_topic(), {:operations, operations})
    state
  end

  defp handle_actions(%ServerState{} = state, actions) when is_list(actions) do
    Enum.reduce(actions, state, &handle_action(&2, &1))
  end

  defp handle_action(
         %ServerState{} = state,
         {:compile_artifact, kind, id, %Workspace{} = workspace}
       ) do
    _ = Runtime.compile(workspace, kind, id)
    sync_artifact_runtime(state)
  end

  defp handle_action(%ServerState{} = state, {:delete_artifact, kind, id}) do
    _ = Runtime.delete_artifact(kind, id)
    sync_artifact_runtime(state)
  end

  defp handle_action(
         %ServerState{} = state,
         {:reconcile_runtime, %Workspace{} = workspace, runtime}
       ) do
    case RuntimeOwner.reconcile(workspace, runtime) do
      {:ok, operations} ->
        state
        |> apply_feedback_operations(operations)
        |> sync_artifact_runtime()

      {:error, reason} ->
        state
        |> apply_feedback_operations([{:runtime_failed, runtime.desired, reason}])
        |> sync_artifact_runtime()
    end
  end

  defp handle_action(
         %ServerState{} = state,
         {:start_sequence_run, sequence_id, sequence_module, runtime}
       ) do
    case SequenceOwner.start_run(sequence_id, sequence_module, runtime) do
      {:ok, operations} ->
        apply_feedback_operations(state, operations)

      {:error, reason} ->
        apply_feedback_operations(
          state,
          [
            {:sequence_run_failed,
             %{
               sequence_id: sequence_id,
               sequence_module: sequence_module,
               deployment_id: runtime.deployment_id,
               topology_module: runtime.active_topology_module,
               finished_at: System.system_time(:millisecond),
               last_error: reason
             }}
          ]
        )
    end
  end

  defp handle_action(%ServerState{} = state, :cancel_sequence_run) do
    case SequenceOwner.cancel_run() do
      {:ok, operations} ->
        apply_feedback_operations(state, operations)

      {:error, :sequence_run_not_active} ->
        state

      {:error, reason} ->
        apply_feedback_operations(
          state,
          [
            {:sequence_run_failed,
             %{
               sequence_id: nil,
               sequence_module: nil,
               deployment_id: State.runtime(state.session_state).deployment_id,
               topology_module: State.runtime(state.session_state).active_topology_module,
               finished_at: System.system_time(:millisecond),
               last_error: reason
             }}
          ]
        )
    end
  end

  defp apply_feedback_operations(%ServerState{} = state, operations) when is_list(operations) do
    Enum.reduce(operations, state, fn operation, %ServerState{} = current_state ->
      case State.apply_operation(current_state.session_state, operation) do
        {:ok, next_session_state, _reply, accepted_operations, actions} ->
          %ServerState{current_state | session_state: next_session_state}
          |> broadcast_operations(accepted_operations)
          |> handle_actions(actions)

        :error ->
          current_state
      end
    end)
  end

  defp sync_artifact_runtime(%ServerState{} = state) do
    case Runtime.artifact_statuses() do
      statuses when is_list(statuses) ->
        apply_feedback_operations(state, [{:replace_artifact_runtime, statuses}])

      _other ->
        state
    end
  end
end
