defmodule Ogol.Session do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.Surface.Defaults, as: SurfaceDefaults
  alias Ogol.Hardware.Config, as: HardwareConfig
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.Runtime
  alias Ogol.Runtime.{Bus, CommandGateway, EventLog, SnapshotStore}
  alias Ogol.Runtime.Hardware.Context, as: HardwareContext
  alias Ogol.Runtime.Hardware.Diff, as: HardwareDiff
  alias Ogol.Runtime.Hardware.Gateway, as: HardwareGateway
  alias Ogol.Session.{Data, RevisionFile, Revisions, Workspace}
  alias Ogol.Studio.Examples

  @dispatch_timeout 15_000
  @action_timeout :infinity
  @type kind :: Data.kind()
  @type client_id :: String.t()

  defmodule State do
    @moduledoc false

    @type active_action :: %{
            from: GenServer.from(),
            pid: pid(),
            monitor_ref: reference(),
            action: Data.action()
          }

    @type queued_call ::
            {:dispatch, GenServer.from(), Data.operation()}
            | {:perform_action, GenServer.from(), Data.action()}

    @type t :: %__MODULE__{
            data: Data.t(),
            next_client_number: pos_integer(),
            client_ids: %{optional(pid()) => Ogol.Session.client_id()},
            client_monitors: %{optional(reference()) => pid()},
            active_action: active_action() | nil,
            queued_calls: :queue.queue(queued_call())
          }

    defstruct data: Data.new(),
              next_client_number: 1,
              client_ids: %{},
              client_monitors: %{},
              active_action: nil,
              queued_calls: :queue.new()
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  defdelegate driver_default_id(), to: Data
  defdelegate hardware_config_entry_id(), to: Data
  defdelegate machine_default_id(), to: Data
  defdelegate topology_default_id(), to: Data

  def dispatch(operation, timeout \\ @dispatch_timeout) do
    GenServer.call(__MODULE__, {:dispatch, operation}, timeout)
  end

  def perform_action(action, timeout \\ @action_timeout) do
    GenServer.call(__MODULE__, {:perform_action, action}, timeout)
  end

  @spec register_client(pid()) :: {Data.t(), client_id()}
  def register_client(client_pid) when is_pid(client_pid) do
    GenServer.call(__MODULE__, {:register_client, client_pid}, @dispatch_timeout)
  end

  @spec get_data() :: Data.t()
  def get_data do
    GenServer.call(__MODULE__, :get_data, @dispatch_timeout)
  end

  def reset_drivers, do: dispatch({:reset_kind, :driver})

  def replace_drivers(drafts) when is_list(drafts),
    do: dispatch({:replace_entries, :driver, drafts})

  def list_drivers, do: list_entries(:driver)
  def fetch_driver(id) when is_binary(id), do: fetch(:driver, id)
  def create_driver(id \\ nil), do: dispatch({:create_entry, :driver, normalize_create_id(id)})

  def save_driver_source(id, source, model, sync_state, sync_diagnostics) do
    dispatch({:save_source, :driver, id, source, model, sync_state, sync_diagnostics})
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

  def reset_hardware_config, do: dispatch({:reset_kind, :hardware_config})

  def replace_hardware_configs(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :hardware_config, drafts})
  end

  def list_hardware_configs, do: list_entries(:hardware_config)
  def fetch_hardware_config, do: fetch(:hardware_config, hardware_config_entry_id())
  def current_hardware_config, do: Data.current_hardware_config(get_data())

  def save_hardware_config_source(source, model, sync_state, sync_diagnostics) do
    dispatch(
      {:save_source, :hardware_config, hardware_config_entry_id(), source, model, sync_state,
       sync_diagnostics}
    )
  end

  def put_hardware_config(%HardwareConfig{} = config) do
    save_hardware_config_source(HardwareConfigSource.to_source(config), config, :synced, [])
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

  def list_kind(kind) when is_atom(kind), do: Data.list_kind(get_data(), kind)

  def fetch(kind, id) when is_atom(kind) and is_binary(id), do: Data.fetch(get_data(), kind, id)

  def loaded_inventory do
    case loaded_revision() do
      %Workspace.LoadedRevision{inventory: inventory} -> inventory
      nil -> []
    end
  end

  def loaded_revision, do: Data.loaded_revision(get_data())

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

  def runtime_status(kind, id), do: Runtime.status(kind, id)
  def runtime_current(kind, id), do: Runtime.current(kind, id)
  def active_manifest, do: Runtime.active_manifest()
  def machine_contract(module_name), do: Runtime.machine_contract(module_name)
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
  defdelegate capture_ethercat_hardware_config(params), to: HardwareGateway
  defdelegate preview_ethercat_simulation_config(form), to: HardwareGateway
  defdelegate promote_candidate_config(config), to: HardwareGateway
  defdelegate arm_candidate_release(), to: HardwareGateway
  defdelegate rollback_armed_release(version), to: HardwareGateway
  defdelegate preview_ethercat_hardware_config(params), to: HardwareGateway
  defdelegate configure_ethercat_slave(slave_name, params), to: HardwareGateway
  defdelegate activate_ethercat(), to: HardwareGateway
  defdelegate deactivate_ethercat(state_target), to: HardwareGateway
  defdelegate capture_support_snapshot(params), to: HardwareGateway
  defdelegate ethercat_session(), to: HardwareGateway
  defdelegate current_candidate_release(), to: HardwareGateway
  defdelegate current_armed_release(), to: HardwareGateway
  defdelegate release_history(), to: HardwareGateway
  defdelegate list_support_snapshots(), to: HardwareGateway
  defdelegate default_ethercat_simulation_form(), to: HardwareGateway
  defdelegate candidate_vs_armed_diff(), to: HardwareGateway
  defdelegate available_raw_interfaces(), to: HardwareGateway
  defdelegate get_support_snapshot(snapshot_id), to: HardwareGateway
  defdelegate available_simulation_drivers(), to: HardwareGateway
  defdelegate ethercat_form_from_config(config), to: HardwareGateway

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:register_client, client_pid}, _from, %State{} = state) do
    case Map.fetch(state.client_ids, client_pid) do
      {:ok, client_id} ->
        {:reply, {state.data, client_id}, state}

      :error ->
        client_id = next_client_id(state)
        monitor_ref = Process.monitor(client_pid)

        next_state = %State{
          state
          | next_client_number: state.next_client_number + 1,
            client_ids: Map.put(state.client_ids, client_pid, client_id),
            client_monitors: Map.put(state.client_monitors, monitor_ref, client_pid)
        }

        {:reply, {state.data, client_id}, next_state}
    end
  end

  def handle_call(:get_data, _from, %State{} = state) do
    {:reply, state.data, state}
  end

  def handle_call({:dispatch, operation}, from, %State{} = state) do
    case state.active_action do
      nil ->
        {:reply, reply, next_state} = execute_dispatch(state, operation)
        {:reply, reply, next_state}

      _active_action ->
        {:noreply, enqueue_call(state, {:dispatch, from, operation})}
    end
  end

  def handle_call({:perform_action, action}, from, %State{} = state) do
    case state.active_action do
      nil ->
        case Data.prepare_action(state.data, action) do
          {:ok, prepared_action} ->
            {:noreply, start_action(state, from, prepared_action)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _active_action ->
        {:noreply, enqueue_call(state, {:perform_action, from, action})}
    end
  end

  @impl true
  def handle_info(
        {:action_finished, pid, result},
        %State{active_action: active_action} = state
      )
      when not is_nil(active_action) and active_action.pid == pid do
    Process.demonitor(active_action.monitor_ref, [:flush])
    GenServer.reply(active_action.from, result)
    {:noreply, drain_queued_calls(%State{state | active_action: nil})}
  end

  def handle_info({:action_finished, _pid, _result}, %State{} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, client_pid, _reason}, %State{} = state) do
    case state.active_action do
      %{monitor_ref: ^monitor_ref, from: from} ->
        GenServer.reply(from, {:error, :action_crashed})
        {:noreply, drain_queued_calls(%State{state | active_action: nil})}

      _active_action ->
        case Map.pop(state.client_monitors, monitor_ref) do
          {nil, _client_monitors} ->
            {:noreply, state}

          {_pid, client_monitors} ->
            {:noreply,
             %State{
               state
               | client_ids: Map.delete(state.client_ids, client_pid),
                 client_monitors: client_monitors
             }}
        end
    end
  end

  defp list_entries(kind), do: Data.list_entries(get_data(), kind)

  defp normalize_create_id(nil), do: :auto
  defp normalize_create_id(id), do: id

  defp next_client_id(%State{} = state), do: "c#{state.next_client_number}"

  defp execute_dispatch(%State{} = state, operation) do
    {:ok, next_data, reply, accepted_operations} = Data.apply_operation(state.data, operation)
    broadcast_operations(accepted_operations)
    {:reply, reply, %State{state | data: next_data}}
  end

  defp broadcast_operations([]), do: :ok

  defp broadcast_operations(operations) when is_list(operations) do
    Bus.broadcast(Bus.workspace_topic(), {:operations, operations})
  end

  defp start_action(%State{} = state, from, action) do
    owner = self()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result = run_action(action)
        send(owner, {:action_finished, self(), result})
      end)

    %State{
      state
      | active_action: %{from: from, pid: pid, monitor_ref: monitor_ref, action: action}
    }
  end

  defp run_action({:compile_artifact, kind, id}), do: Runtime.compile(kind, id)
  defp run_action({:deploy_topology, id}), do: Runtime.deploy_topology(id)
  defp run_action({:stop_topology, id}), do: Runtime.stop_topology(id)
  defp run_action(:stop_active), do: Runtime.stop_active()
  defp run_action(:restart_active), do: Runtime.restart_active()

  defp enqueue_call(%State{} = state, call) do
    %State{state | queued_calls: :queue.in(call, state.queued_calls)}
  end

  defp drain_queued_calls(%State{active_action: nil} = state) do
    case :queue.out(state.queued_calls) do
      {{:value, {:dispatch, from, operation}}, queued_calls} ->
        {:reply, reply, next_state} =
          execute_dispatch(%State{state | queued_calls: queued_calls}, operation)

        GenServer.reply(from, reply)
        drain_queued_calls(next_state)

      {{:value, {:perform_action, from, action}}, queued_calls} ->
        next_state = %State{state | queued_calls: queued_calls}

        case Data.prepare_action(next_state.data, action) do
          {:ok, prepared_action} ->
            start_action(next_state, from, prepared_action)

          {:error, reason} ->
            GenServer.reply(from, {:error, reason})
            drain_queued_calls(next_state)
        end

      {:empty, _queued_calls} ->
        state
    end
  end
end
