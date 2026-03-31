defmodule Ogol.Studio.WorkspaceStore do
  @moduledoc false

  use GenServer

  alias Ogol.HMI.Bus
  alias Ogol.Studio.Build
  alias Ogol.Studio.Build.Artifact
  alias Ogol.Studio.DemoSeed
  alias Ogol.Studio.TopologyRuntime
  alias Ogol.Driver.Parser, as: DriverParser
  alias Ogol.Driver.Source, as: DriverSource
  alias Ogol.HardwareConfig
  alias Ogol.HardwareConfig.Source, as: HardwareConfigSource
  alias Ogol.HMI.Surface
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Topology.Source, as: TopologySource

  @default_driver_id "packaging_outputs"
  @hardware_config_entry_id "hardware_config"
  @default_machine_ids ["packaging_line", "inspection_cell", "palletizer_cell"]
  @default_topology_ids ["packaging_line", "inspection_cell", "palletizer_cell"]
  @dispatch_timeout 15_000

  defmodule LoadedRevision do
    @moduledoc false

    @type inventory_item :: %{
            kind: atom(),
            id: String.t(),
            module: module()
          }

    @type t :: %__MODULE__{
            app_id: String.t() | nil,
            revision: String.t() | nil,
            inventory: [inventory_item()]
          }

    defstruct app_id: nil, revision: nil, inventory: []
  end

  defmodule DriverDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :partial | :unsupported,
            sync_diagnostics: [term()],
            build_diagnostics: [term()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: [],
      build_diagnostics: []
    ]
  end

  defmodule MachineDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()],
            build_diagnostics: [term()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: [],
      build_diagnostics: []
    ]
  end

  defmodule TopologyDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()],
            compile_diagnostics: [String.t()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: [],
      compile_diagnostics: []
    ]
  end

  defmodule SequenceDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()],
            compile_diagnostics: [String.t()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: [],
      compile_diagnostics: []
    ]
  end

  defmodule HardwareConfigDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: HardwareConfig.t() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()],
            compile_diagnostics: [String.t()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: [],
      compile_diagnostics: []
    ]
  end

  defmodule HmiSurfaceDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            source_module: module(),
            model: Surface.t() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()]
          }

    defstruct [
      :id,
      :source,
      :source_module,
      :model,
      sync_state: :synced,
      sync_diagnostics: []
    ]
  end

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            entries: %{optional(atom()) => %{optional(String.t()) => term()}},
            runtime_entries: %{optional(term()) => RuntimeEntry.t()},
            loaded_revision: LoadedRevision.t() | nil
          }

    defstruct entries: %{
                driver: %{},
                machine: %{},
                topology: %{},
                sequence: %{},
                hardware_config: %{},
                hmi_surface: %{}
              },
              runtime_entries: %{},
              loaded_revision: nil
  end

  defmodule RuntimeEntry do
    @moduledoc false

    @type t :: %__MODULE__{
            id: term(),
            module: module() | nil,
            source_digest: String.t() | nil,
            blocked_reason: term() | nil,
            lingering_pids: [pid()]
          }

    defstruct [
      :id,
      :module,
      :source_digest,
      :blocked_reason,
      lingering_pids: []
    ]
  end

  @type kind :: :driver | :machine | :topology | :sequence | :hardware_config | :hmi_surface

  @type action ::
          {:compile_and_load, kind(), String.t(), String.t(), map() | nil}
          | {:start_topology_runtime, String.t(), String.t(), map() | nil}
          | {:stop_topology_runtime, String.t(), String.t(), map() | nil}

  @type operation ::
          {:reset_kind, kind()}
          | {:replace_entries, kind(), [term()]}
          | {:create_entry, kind(), String.t() | :auto}
          | {:save_source, kind(), String.t(), String.t(), map() | nil, atom(), [term()]}
          | {:save_hmi_surface_source, String.t(), String.t(), module(), Surface.t() | nil,
             atom(), [term()]}
          | {:record_compile, kind(), String.t(), [term()]}
          | {:compile_entry, kind(), String.t()}
          | {:start_topology, String.t()}
          | {:stop_topology, String.t()}
          | {:runtime_mark_loaded, term(), module(), String.t()}
          | {:runtime_mark_blocked, term(), [pid()]}
          | {:runtime_mark_error, term(), term()}
          | {:runtime_delete, term()}
          | {:put_loaded_revision, String.t() | nil, String.t() | nil,
             [LoadedRevision.inventory_item()]}
          | {:set_loaded_revision_id, String.t() | nil}
          | :reset_runtime
          | :reset_loaded_revision

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def driver_default_id, do: @default_driver_id
  def hardware_config_entry_id, do: @hardware_config_entry_id
  def machine_default_id, do: hd(machine_default_ids())
  def topology_default_id, do: hd(topology_default_ids())

  def dispatch(operation, timeout \\ @dispatch_timeout) do
    GenServer.call(__MODULE__, {:dispatch, operation}, timeout)
  end

  def compile_driver(id) when is_binary(id) do
    dispatch({:compile_entry, :driver, id})
  end

  def compile_machine(id) when is_binary(id) do
    dispatch({:compile_entry, :machine, id})
  end

  def compile_topology(id) when is_binary(id) do
    dispatch({:compile_entry, :topology, id})
  end

  def compile_sequence(id) when is_binary(id) do
    dispatch({:compile_entry, :sequence, id})
  end

  def compile_hardware_config do
    dispatch({:compile_entry, :hardware_config, @hardware_config_entry_id})
  end

  def start_topology(id) when is_binary(id) do
    dispatch({:start_topology, id})
  end

  def stop_topology(id) when is_binary(id) do
    dispatch({:stop_topology, id})
  end

  def apply_artifact(id, %Artifact{} = artifact) do
    GenServer.call(__MODULE__, {:apply_artifact, id, artifact})
  end

  def reset_runtime_modules do
    GenServer.call(__MODULE__, :reset_runtime_modules)
  end

  @spec apply_operation(State.t(), operation()) ::
          {:ok, State.t(), [action()], term()} | :error
  def apply_operation(%State{} = state, operation) do
    case operation do
      {:compile_entry, kind, id}
      when kind in [:driver, :machine, :topology, :sequence, :hardware_config] ->
        case fetch_entry(state, kind, id) do
          nil ->
            :error

          entry ->
            {:ok, state, [{:compile_and_load, kind, id, entry.source, Map.get(entry, :model)}],
             nil}
        end

      {:start_topology, id} ->
        case fetch_entry(state, :topology, id) do
          nil ->
            :error

          entry ->
            {:ok, state, [{:start_topology_runtime, id, entry.source, Map.get(entry, :model)}],
             nil}
        end

      {:stop_topology, id} ->
        case fetch_entry(state, :topology, id) do
          nil ->
            :error

          entry ->
            {:ok, state, [{:stop_topology_runtime, id, entry.source, Map.get(entry, :model)}],
             nil}
        end

      _other ->
        {reply, next_state} = reduce(state, operation)
        {:ok, next_state, [], reply}
    end
  end

  @spec reduce(State.t(), operation()) :: {term(), State.t()}
  def reduce(%State{} = state, operation) do
    case operation do
      {:reset_kind, kind} ->
        next_state =
          state
          |> put_in([Access.key(:entries), Access.key(kind)], default_entries(kind))
          |> clear_loaded_revision()

        {:ok, next_state}

      {:replace_entries, kind, drafts} ->
        kind_entries =
          drafts
          |> Map.new(fn draft -> {draft_id(draft), draft} end)

        {:ok,
         state
         |> put_in([Access.key(:entries), Access.key(kind)], kind_entries)
         |> clear_loaded_revision()}

      {:create_entry, kind, :auto} ->
        id = next_available_id(state, kind, kind_prefix(kind))
        reduce(state, {:create_entry, kind, id})

      {:create_entry, kind, id} when is_binary(id) ->
        entry = seeded_entry(state, kind, id)

        {entry,
         state
         |> put_entry(kind, id, entry)
         |> clear_loaded_revision()}

      {:save_source, kind, id, source, model, sync_state, sync_diagnostics} ->
        entry = fetch_entry(state, kind, id) || seeded_entry(state, kind, id)
        source_changed? = entry.source != source

        updated =
          entry
          |> Map.put(:source, source)
          |> Map.put(:model, model)
          |> Map.put(:sync_state, sync_state)
          |> Map.put(:sync_diagnostics, sync_diagnostics)
          |> maybe_reset_compile_diagnostics(source_changed?)

        next_state =
          state
          |> put_entry(kind, id, updated)
          |> maybe_clear_loaded_revision(source_changed?)

        {updated, next_state}

      {:save_hmi_surface_source, id, source, source_module, model, sync_state, sync_diagnostics} ->
        entry =
          fetch_entry(state, :hmi_surface, id) || seeded_hmi_surface_draft(id, source_module)

        source_changed? = entry.source != source

        updated = %{
          entry
          | source: source,
            source_module: source_module,
            model: model,
            sync_state: sync_state,
            sync_diagnostics: sync_diagnostics
        }

        next_state =
          state
          |> put_entry(:hmi_surface, id, updated)
          |> maybe_clear_loaded_revision(source_changed?)

        {updated, next_state}

      {:record_compile, kind, id, diagnostics} ->
        entry = fetch_entry(state, kind, id) || seeded_entry(state, kind, id)
        updated = put_compile_diagnostics(entry, diagnostics)
        {updated, put_entry(state, kind, id, updated)}

      {:runtime_mark_loaded, id, module, source_digest} ->
        entry = fetch_runtime_entry(state, id) || %RuntimeEntry{id: id}

        updated = %{
          entry
          | module: module,
            source_digest: source_digest,
            blocked_reason: nil,
            lingering_pids: []
        }

        {updated, put_in(state.runtime_entries[id], updated)}

      {:runtime_mark_blocked, id, lingering_pids} ->
        entry = fetch_runtime_entry(state, id) || %RuntimeEntry{id: id}

        updated = %{
          entry
          | blocked_reason: :old_code_in_use,
            lingering_pids: lingering_pids
        }

        {updated, put_in(state.runtime_entries[id], updated)}

      {:runtime_mark_error, id, reason} ->
        entry = fetch_runtime_entry(state, id) || %RuntimeEntry{id: id}
        updated = %{entry | blocked_reason: reason}
        {updated, put_in(state.runtime_entries[id], updated)}

      {:runtime_delete, id} ->
        {fetch_runtime_entry(state, id), update_in(state.runtime_entries, &Map.delete(&1, id))}

      {:put_loaded_revision, app_id, revision, inventory} ->
        loaded_revision = %LoadedRevision{
          app_id: app_id,
          revision: revision,
          inventory: inventory
        }

        {loaded_revision, %State{state | loaded_revision: loaded_revision}}

      {:set_loaded_revision_id, revision} ->
        loaded_revision =
          state.loaded_revision
          |> Kernel.||(%LoadedRevision{})
          |> Map.put(:revision, revision)

        {loaded_revision, %State{state | loaded_revision: loaded_revision}}

      :reset_runtime ->
        {:ok, %State{state | runtime_entries: %{}}}

      :reset_loaded_revision ->
        {:ok, %State{state | loaded_revision: nil}}
    end
  end

  def reset_drivers do
    dispatch({:reset_kind, :driver})
  end

  def replace_drivers(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :driver, drafts})
  end

  def list_drivers, do: list_entries(:driver)

  def fetch_driver(id) when is_binary(id) do
    fetch(:driver, id)
  end

  def create_driver(id \\ nil) do
    dispatch({:create_entry, :driver, normalize_create_id(id)})
  end

  def save_driver_source(id, source, model, sync_state, sync_diagnostics) do
    dispatch({:save_source, :driver, id, source, model, sync_state, sync_diagnostics})
  end

  def reset_machines do
    dispatch({:reset_kind, :machine})
  end

  def replace_machines(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :machine, drafts})
  end

  def list_machines, do: list_entries(:machine)

  def fetch_machine(id) when is_binary(id) do
    fetch(:machine, id)
  end

  def create_machine(id \\ nil) do
    dispatch({:create_entry, :machine, normalize_create_id(id)})
  end

  def save_machine_source(id, source, model, sync_state, sync_diagnostics) do
    dispatch({:save_source, :machine, id, source, model, sync_state, sync_diagnostics})
  end

  def reset_topologies do
    dispatch({:reset_kind, :topology})
  end

  def replace_topologies(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :topology, drafts})
  end

  def list_topologies, do: list_entries(:topology)

  def fetch_topology(id) when is_binary(id) do
    fetch(:topology, id)
  end

  def create_topology(id \\ nil) do
    dispatch({:create_entry, :topology, normalize_create_id(id)})
  end

  def save_topology_source(id, source, model, sync_state, sync_diagnostics) do
    dispatch({:save_source, :topology, id, source, model, sync_state, sync_diagnostics})
  end

  def reset_sequences do
    dispatch({:reset_kind, :sequence})
  end

  def replace_sequences(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :sequence, drafts})
  end

  def list_sequences, do: list_entries(:sequence)

  def fetch_sequence(id) when is_binary(id) do
    fetch(:sequence, id)
  end

  def create_sequence(id \\ nil) do
    dispatch({:create_entry, :sequence, normalize_create_id(id)})
  end

  def save_sequence_source(id, source, model, sync_state, sync_diagnostics) do
    dispatch({:save_source, :sequence, id, source, model, sync_state, sync_diagnostics})
  end

  def reset_hardware_config do
    dispatch({:reset_kind, :hardware_config})
  end

  def replace_hardware_configs(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :hardware_config, drafts})
  end

  def list_hardware_configs, do: list_entries(:hardware_config)

  def fetch_hardware_config do
    fetch(:hardware_config, @hardware_config_entry_id)
  end

  def current_hardware_config do
    case fetch_hardware_config() do
      %{model: %HardwareConfig{} = config} -> config
      %{source: source} when is_binary(source) -> config_from_source(source)
      _other -> nil
    end
  end

  def save_hardware_config_source(source, model, sync_state, sync_diagnostics) do
    dispatch(
      {:save_source, :hardware_config, @hardware_config_entry_id, source, model, sync_state,
       sync_diagnostics}
    )
  end

  def put_hardware_config(%HardwareConfig{} = config) do
    save_hardware_config_source(
      HardwareConfigSource.to_source(config),
      config,
      :synced,
      []
    )
  end

  def reset_hmi_surfaces do
    replace_hmi_surfaces(Ogol.HMI.SurfaceDefaults.drafts_from_workspace())
  end

  def replace_hmi_surfaces(drafts) when is_list(drafts) do
    dispatch({:replace_entries, :hmi_surface, drafts})
  end

  def list_hmi_surfaces, do: list_entries(:hmi_surface)

  def fetch_hmi_surface(id) when is_binary(id) do
    fetch(:hmi_surface, id)
  end

  def save_hmi_surface_source(id, source, source_module, model, sync_state, sync_diagnostics)
      when is_binary(id) and is_binary(source) and is_atom(source_module) do
    dispatch(
      {:save_hmi_surface_source, id, source, source_module, model, sync_state, sync_diagnostics}
    )
  end

  def list_kind(kind) when is_atom(kind) do
    GenServer.call(__MODULE__, {:list_kind, kind})
  end

  def fetch(kind, id) when is_atom(kind) and is_binary(id) do
    GenServer.call(__MODULE__, {:fetch, kind, id})
  end

  def loaded_inventory do
    case loaded_revision() do
      %LoadedRevision{inventory: inventory} -> inventory
      nil -> []
    end
  end

  def loaded_revision do
    GenServer.call(__MODULE__, :loaded_revision)
  end

  def put_loaded_revision(app_id, revision, inventory) when is_list(inventory) do
    dispatch({:put_loaded_revision, app_id, revision, inventory})
  end

  def set_loaded_revision_id(revision) when is_binary(revision) or is_nil(revision) do
    dispatch({:set_loaded_revision_id, revision})
  end

  def runtime_fetch(id) do
    GenServer.call(__MODULE__, {:runtime_fetch, id})
  end

  def runtime_list do
    GenServer.call(__MODULE__, :runtime_list)
  end

  def runtime_mark_loaded(id, module, source_digest) do
    dispatch({:runtime_mark_loaded, id, module, source_digest})
  end

  def runtime_mark_blocked(id, lingering_pids) do
    dispatch({:runtime_mark_blocked, id, lingering_pids})
  end

  def runtime_mark_error(id, reason) do
    dispatch({:runtime_mark_error, id, reason})
  end

  def runtime_delete(id) do
    dispatch({:runtime_delete, id})
  end

  def reset_runtime do
    dispatch(:reset_runtime)
  end

  def reset_loaded_revision do
    dispatch(:reset_loaded_revision)
  end

  @impl true
  def init(_opts) do
    {:ok, %State{entries: initial_entries()}}
  end

  @impl true
  def handle_call({:dispatch, operation}, _from, %State{} = state) do
    case apply_operation(state, operation) do
      {:ok, next_state, actions, reply} ->
        {final_reply, final_state} = execute_actions(next_state, actions, reply)
        broadcast_workspace_event(operation, final_reply, final_state)
        {:reply, final_reply, final_state}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call({:apply_artifact, id, %Artifact{} = artifact}, _from, %State{} = state) do
    {reply, next_state} = apply_artifact_internal(state, id, artifact)
    broadcast_workspace_event({:apply_artifact, id}, reply, next_state)
    {:reply, reply, next_state}
  end

  def handle_call(:reset_runtime_modules, _from, %State{} = state) do
    {reply, next_state} = reset_runtime_modules_internal(state)
    broadcast_workspace_event(:reset_runtime_modules, reply, next_state)
    {:reply, reply, next_state}
  end

  def handle_call({:list_kind, kind}, _from, %State{} = state) do
    entries =
      state.entries
      |> Map.get(kind, %{})
      |> Enum.sort_by(fn {id, _entry} -> id end)

    {:reply, entries, state}
  end

  def handle_call({:fetch, kind, id}, _from, %State{} = state) do
    entry =
      state.entries
      |> Map.get(kind, %{})
      |> Map.get(id)

    {:reply, entry, state}
  end

  def handle_call({:runtime_fetch, id}, _from, %State{} = state) do
    {:reply, fetch_runtime_entry(state, id), state}
  end

  def handle_call(:runtime_list, _from, %State{} = state) do
    entries =
      state.runtime_entries
      |> Map.values()
      |> Enum.sort_by(&inspect(&1.id))

    {:reply, entries, state}
  end

  def handle_call(:loaded_revision, _from, %State{} = state) do
    {:reply, state.loaded_revision, state}
  end

  defp execute_actions(state, [], reply), do: {reply, state}

  defp execute_actions(state, [action | rest], reply) do
    {action_reply, next_state} = execute_action(state, action)
    execute_actions(next_state, rest, action_reply || reply)
  end

  defp execute_action(%State{} = state, {:compile_and_load, :sequence, id, source, _model}) do
    case build_sequence_artifact(state, id, source) do
      {:ok, artifact} ->
        {apply_reply, next_state} =
          apply_artifact_internal(state, runtime_id(:sequence, id), artifact)

        diagnostics = compile_validation_diagnostics(:sequence, artifact.module)
        updated_state = update_compile_diagnostics(next_state, :sequence, id, diagnostics)
        draft = fetch_entry(updated_state, :sequence, id)

        reply =
          case {apply_reply, diagnostics} do
            {{:ok, _result}, []} ->
              {:ok, draft}

            {{:ok, _result}, diagnostics} ->
              {:error, diagnostics, draft}

            {{:blocked, _blocked}, _diagnostics} ->
              {:ok, draft}

            {{:error, _reason}, _diagnostics} ->
              {:ok, draft}
          end

        {reply, updated_state}

      {:error, :module_not_found} ->
        draft = fetch_entry(state, :sequence, id)
        {{:error, :module_not_found, draft}, state}

      {:error, diagnostics} ->
        updated_state = update_compile_diagnostics(state, :sequence, id, diagnostics)
        draft = fetch_entry(updated_state, :sequence, id)
        {{:error, diagnostics, draft}, updated_state}
    end
  end

  defp execute_action(%State{} = state, {:compile_and_load, :topology, id, source, model}) do
    with {:ok, topology_model} <- topology_compile_model(source, model),
         {:ok, machine_state} <- ensure_machine_runtime_contexts(state, topology_model) do
      execute_compile_and_load(machine_state, :topology, id, source, topology_model)
    else
      {:blocked, _details, next_state} = blocked ->
        draft = fetch_entry(next_state, :topology, id)
        {{:error, [inspect(blocked)], draft}, next_state}

      {:error, reason, next_state} ->
        diagnostics = [inspect(reason)]
        updated_state = update_compile_diagnostics(next_state, :topology, id, diagnostics)
        draft = fetch_entry(updated_state, :topology, id)
        {{:error, diagnostics, draft}, updated_state}

      {:error, diagnostics} when is_list(diagnostics) ->
        updated_state = update_compile_diagnostics(state, :topology, id, diagnostics)
        draft = fetch_entry(updated_state, :topology, id)
        {{:error, diagnostics, draft}, updated_state}
    end
  end

  defp execute_action(
         %State{} = state,
         {:compile_and_load, kind, id, source, model}
       ) do
    execute_compile_and_load(state, kind, id, source, model)
  end

  defp execute_action(%State{} = state, {:start_topology_runtime, id, source, model}) do
    with {:ok, module} <- topology_runtime_module(source, model),
         :ok <- ensure_runtime_module_current(state, :topology, id, source, module),
         :ok <- TopologyRuntime.preflight_start_loaded(module),
         {:ok, hardware_state} <- ensure_hardware_runtime_activated(state) do
      case ensure_machine_runtime_contexts(hardware_state, model) do
        {:ok, machine_state} ->
          case TopologyRuntime.start_loaded(module, model) do
            {:ok, %{module: ^module, pid: pid}} ->
              {{:ok, %{module: module, pid: pid}}, machine_state}

            {:error, _reason} = error ->
              {error, machine_state}
          end

        {:blocked, details, machine_state} ->
          {{:blocked, details}, machine_state}

        {:error, reason, machine_state} ->
          {{:error, reason}, machine_state}
      end
    else
      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp execute_action(%State{} = state, {:stop_topology_runtime, _id, source, model}) do
    reply =
      with {:ok, module} <- topology_runtime_module(source, model) do
        TopologyRuntime.stop_loaded(module)
      else
        {:error, :module_not_found} ->
          {:error, :module_not_found}

        {:error, _reason} = error ->
          error
      end

    {reply, state}
  end

  defp execute_compile_and_load(%State{} = state, kind, id, source, model) do
    case build_artifact(kind, id, source, model) do
      {:ok, artifact} ->
        {apply_reply, next_state} = apply_artifact_internal(state, runtime_id(kind, id), artifact)
        diagnostics = compile_validation_diagnostics(kind, artifact.module)
        updated_state = update_compile_diagnostics(next_state, kind, id, diagnostics)
        draft = fetch_entry(updated_state, kind, id)

        reply =
          case {apply_reply, diagnostics} do
            {{:ok, _result}, []} ->
              {:ok, draft}

            {{:ok, _result}, diagnostics} ->
              {:error, diagnostics, draft}

            {{:blocked, _blocked}, _diagnostics} ->
              {:ok, draft}

            {{:error, _reason}, _diagnostics} ->
              {:ok, draft}
          end

        {reply, updated_state}

      {:error, :module_not_found} ->
        draft = fetch_entry(state, kind, id)
        {{:error, :module_not_found, draft}, state}

      {:error, diagnostics} ->
        updated_state = update_compile_diagnostics(state, kind, id, diagnostics)
        draft = fetch_entry(updated_state, kind, id)
        {{:error, diagnostics, draft}, updated_state}
    end
  end

  defp ensure_hardware_runtime_activated(%State{} = state) do
    with {:ok, draft} <- fetch_hardware_config_draft(state),
         {:ok, runtime_state, module} <- ensure_hardware_runtime_current(state, draft),
         {:ok, _runtime} <- ensure_hardware_runtime_ready(draft, module) do
      {:ok, runtime_state}
    else
      {:blocked, _details, _runtime_state} = blocked ->
        blocked

      {:error, _reason, _runtime_state} = error ->
        error

      {:error, reason} ->
        {:error, {:hardware_activation_failed, reason}, state}
    end
  end

  defp fetch_hardware_config_draft(%State{} = state) do
    case fetch_entry(state, :hardware_config, @hardware_config_entry_id) do
      %HardwareConfigDraft{} = draft -> {:ok, draft}
      nil -> {:error, :no_hardware_config_available}
    end
  end

  defp ensure_hardware_runtime_current(%State{} = state, %HardwareConfigDraft{} = draft) do
    with {:ok, module} <- HardwareConfigSource.module_from_source(draft.source) do
      case ensure_runtime_module_current(
             state,
             :hardware_config,
             draft.id,
             draft.source,
             module
           ) do
        :ok ->
          {:ok, state, module}

        {:error, {:module_not_current, :hardware_config, _id}} ->
          compile_hardware_runtime(state, draft)

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :module_not_found} ->
        {:error, :module_not_found, state}
    end
  end

  defp compile_hardware_runtime(%State{} = state, %HardwareConfigDraft{} = draft) do
    case build_artifact(:hardware_config, draft.id, draft.source, draft.model) do
      {:ok, artifact} ->
        {apply_reply, next_state} =
          apply_artifact_internal(state, runtime_id(:hardware_config, draft.id), artifact)

        next_state = update_compile_diagnostics(next_state, :hardware_config, draft.id, [])

        case apply_reply do
          {:ok, _result} ->
            {:ok, next_state, artifact.module}

          {:blocked, %{module: blocked_module, pids: pids}} ->
            {:blocked, %{reason: :old_code_in_use, module: blocked_module, pids: pids},
             next_state}

          {:error, reason} ->
            {:error, {:hardware_config_apply_failed, draft.id, reason}, next_state}
        end

      {:error, diagnostics} when is_list(diagnostics) ->
        next_state = update_compile_diagnostics(state, :hardware_config, draft.id, diagnostics)
        {:error, {:hardware_config_build_failed, draft.id, diagnostics}, next_state}

      {:error, :module_not_found} ->
        {:error, {:hardware_config_module_not_available, draft.id}, state}
    end
  end

  defp ensure_hardware_runtime_ready(%HardwareConfigDraft{} = draft, module)
       when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:hardware_config_module_not_loaded, draft.id, module}}

      not function_exported?(module, :ensure_ready, 0) ->
        {:error, {:hardware_config_module_missing_ensure_ready, draft.id, module}}

      true ->
        module.ensure_ready()
    end
  end

  defp build_artifact(:driver, id, source, _model) do
    with {:ok, module} <- DriverParser.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} -> {:error, :module_not_found}
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:machine, id, source, _model) do
    with {:ok, module} <- MachineSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} -> {:error, :module_not_found}
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:topology, id, source, %{module_name: module_name})
       when is_binary(module_name) do
    with {:ok, artifact} <- Build.build(id, TopologySource.module_from_name!(module_name), source) do
      {:ok, artifact}
    else
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:topology, _id, _source, _model), do: {:error, :module_not_found}

  defp build_artifact(:hardware_config, id, source, _model) do
    with {:ok, module} <- HardwareConfigSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} -> {:error, :module_not_found}
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_sequence_artifact(%State{} = state, id, source) do
    with {:ok, parsed} <- SequenceSource.from_source(source),
         :ok <- ensure_sequence_runtime_context(state, parsed.topology_module_name),
         {:ok, module} <- SequenceSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} ->
        {:error, :module_not_found}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, diagnostics}

      {:error, %{diagnostics: diagnostics}} ->
        {:error, diagnostics}

      {:error, reason} ->
        {:error, [inspect(reason)]}
    end
  end

  defp compile_validation_diagnostics(:sequence, module) when is_atom(module) do
    if function_exported?(module, :__ogol_sequence__, 0) do
      []
    else
      ["sequence source did not expose `__ogol_sequence__/0` after compile"]
    end
  end

  defp compile_validation_diagnostics(_kind, _module), do: []

  defp ensure_sequence_runtime_context(%State{} = state, topology_module_name)
       when is_binary(topology_module_name) do
    with {:ok, draft} <- fetch_sequence_topology_entry(state, topology_module_name),
         :ok <-
           ensure_sequence_runtime_module_current(
             state,
             :topology,
             draft.id,
             draft.source,
             topology_module_name
           ),
         {:ok, topology_model} <- topology_model_from_entry(draft, topology_module_name),
         :ok <- ensure_sequence_machine_contexts(state, topology_model.machines) do
      :ok
    end
  end

  defp ensure_sequence_machine_contexts(%State{} = state, machines) when is_list(machines) do
    Enum.reduce_while(machines, :ok, fn machine, :ok ->
      case ensure_sequence_machine_context(state, Map.get(machine, :module_name)) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_sequence_machine_contexts(_state, _machines), do: :ok

  defp ensure_sequence_machine_context(%State{} = state, module_name)
       when is_binary(module_name) do
    with {:ok, draft} <- fetch_sequence_machine_entry(state, module_name),
         :ok <-
           ensure_sequence_runtime_module_current(
             state,
             :machine,
             draft.id,
             draft.source,
             module_name
           ) do
      :ok
    end
  end

  defp fetch_sequence_topology_entry(%State{} = state, module_name) do
    case Enum.find(
           Map.values(entries_for_kind(state, :topology)),
           &(entry_module_name(:topology, &1) == module_name)
         ) do
      nil ->
        {:error,
         [
           "Sequence compile targets topology #{module_name}, but that topology is not present in the current workspace."
         ]}

      draft ->
        {:ok, draft}
    end
  end

  defp fetch_sequence_machine_entry(%State{} = state, module_name) do
    case Enum.find(
           Map.values(entries_for_kind(state, :machine)),
           &(entry_module_name(:machine, &1) == module_name)
         ) do
      nil ->
        {:error,
         [
           "Sequence compile references machine module #{module_name}, but that machine is not present in the current workspace."
         ]}

      draft ->
        {:ok, draft}
    end
  end

  defp ensure_sequence_runtime_module_current(%State{} = state, kind, id, source, module_name)
       when is_binary(id) and is_binary(source) and is_binary(module_name) do
    expected_module = SequenceSource.module_from_name!(module_name)
    expected_digest = Build.digest(source)
    runtime_id = runtime_id(kind, id)

    case fetch_runtime_entry(state, runtime_id) do
      %RuntimeEntry{
        module: ^expected_module,
        source_digest: ^expected_digest,
        blocked_reason: nil
      } ->
        :ok

      %RuntimeEntry{blocked_reason: reason} when not is_nil(reason) ->
        {:error, ["#{humanize_kind(kind)} #{id} is blocked in the runtime: #{inspect(reason)}"]}

      _ ->
        {:error, ["Compile #{humanize_kind(kind)} #{id} before compiling this sequence."]}
    end
  end

  defp topology_runtime_module(source, %{module_name: module_name})
       when is_binary(source) and is_binary(module_name) do
    {:ok, TopologySource.module_from_name!(module_name)}
  end

  defp topology_runtime_module(source, _model) when is_binary(source) do
    case TopologySource.from_source(source) do
      {:ok, %{module_name: module_name}} when is_binary(module_name) ->
        {:ok, TopologySource.module_from_name!(module_name)}

      _ ->
        {:error, :module_not_found}
    end
  end

  defp ensure_runtime_module_current(%State{} = state, kind, id, source, module)
       when is_atom(kind) and is_binary(id) and is_binary(source) and is_atom(module) do
    source_digest = Build.digest(source)

    case fetch_runtime_entry(state, runtime_id(kind, id)) do
      %RuntimeEntry{module: ^module, source_digest: ^source_digest, blocked_reason: nil} ->
        :ok

      %RuntimeEntry{blocked_reason: reason} when not is_nil(reason) ->
        {:error, {:module_blocked, kind, id, reason}}

      _ ->
        {:error, {:module_not_current, kind, id}}
    end
  end

  defp ensure_machine_runtime_contexts(%State{} = state, %{machines: machines})
       when is_list(machines) do
    machines
    |> Enum.map(&Map.get(&1, :module_name))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, state}, fn module_name, {:ok, current_state} ->
      case ensure_machine_runtime_current(current_state, module_name) do
        {:ok, next_state} ->
          {:cont, {:ok, next_state}}

        {:blocked, _blocked, _next_state} = blocked ->
          {:halt, blocked}

        {:error, _reason, _next_state} = error ->
          {:halt, error}
      end
    end)
  end

  defp ensure_machine_runtime_contexts(%State{} = state, _model), do: {:ok, state}

  defp topology_compile_model(_source, model) when is_map(model), do: {:ok, model}

  defp topology_compile_model(source, _model) when is_binary(source) do
    case TopologySource.from_source(source) do
      {:ok, parsed_model} -> {:ok, parsed_model}
      {:error, diagnostics} -> {:error, diagnostics}
    end
  end

  defp ensure_machine_runtime_current(%State{} = state, module_name)
       when is_binary(module_name) do
    module = MachineSource.module_from_name!(module_name)

    case machine_draft_for_module(state, module_name) do
      nil ->
        if Code.ensure_loaded?(module) do
          {:ok, state}
        else
          {:error, {:machine_module_not_available, module_name}}
        end

      %MachineDraft{} = draft ->
        source_digest = Build.digest(draft.source)
        runtime_id = runtime_id(:machine, draft.id)

        case fetch_runtime_entry(state, runtime_id) do
          %RuntimeEntry{module: ^module, source_digest: ^source_digest, blocked_reason: nil} ->
            {:ok, state}

          _entry ->
            compile_machine_runtime(state, draft, module_name)
        end
    end
  end

  defp compile_machine_runtime(%State{} = state, %MachineDraft{} = draft, module_name) do
    case build_artifact(:machine, draft.id, draft.source, draft.model) do
      {:ok, artifact} ->
        {apply_reply, next_state} =
          apply_artifact_internal(state, runtime_id(:machine, draft.id), artifact)

        case apply_reply do
          {:ok, _result} ->
            {:ok, update_compile_diagnostics(next_state, :machine, draft.id, [])}

          {:blocked, %{module: blocked_module, pids: pids}} ->
            next_state = update_compile_diagnostics(next_state, :machine, draft.id, [])

            {:blocked, %{reason: :old_code_in_use, module: blocked_module, pids: pids},
             next_state}

          {:error, reason} ->
            {:error, {:machine_apply_failed, draft.id, reason}, next_state}
        end

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, {:machine_build_failed, draft.id, diagnostics}, state}

      {:error, :module_not_found} ->
        {:error, {:machine_module_not_available, module_name}, state}
    end
  end

  defp machine_draft_for_module(%State{} = state, module_name) when is_binary(module_name) do
    state
    |> entries_for_kind(:machine)
    |> Map.values()
    |> Enum.find(fn draft ->
      case draft do
        %{model: %{module_name: ^module_name}} -> true
        _ -> false
      end
    end)
  end

  defp topology_model_from_entry(%{model: model}, _topology_module_name) when is_map(model) do
    {:ok, model}
  end

  defp topology_model_from_entry(%{source: source}, topology_module_name)
       when is_binary(source) do
    case TopologySource.from_source(source) do
      {:ok, model} ->
        {:ok, model}

      {:error, diagnostics} ->
        {:error,
         [
           "Topology #{topology_module_name} could not be recovered from workspace source: #{List.first(diagnostics)}"
         ]}
    end
  end

  defp entry_module_name(:machine, %{model: %{module_name: module_name}})
       when is_binary(module_name),
       do: module_name

  defp entry_module_name(:machine, %{source: source}) when is_binary(source) do
    case MachineSource.module_from_source(source) do
      {:ok, module} -> Atom.to_string(module) |> String.trim_leading("Elixir.")
      _ -> nil
    end
  end

  defp entry_module_name(:topology, %{model: %{module_name: module_name}})
       when is_binary(module_name),
       do: module_name

  defp entry_module_name(:topology, %{source: source}) when is_binary(source) do
    case TopologySource.from_source(source) do
      {:ok, %{module_name: module_name}} when is_binary(module_name) -> module_name
      _ -> nil
    end
  end

  defp entry_module_name(_kind, _entry), do: nil

  defp humanize_kind(:machine), do: "machine"
  defp humanize_kind(:topology), do: "topology"
  defp humanize_kind(:sequence), do: "sequence"
  defp humanize_kind(:hardware_config), do: "hardware config"
  defp humanize_kind(kind), do: to_string(kind)

  defp apply_artifact_internal(%State{} = state, id, %Artifact{} = artifact) do
    entry = fetch_runtime_entry(state, id) || %RuntimeEntry{id: id}

    cond do
      not is_nil(entry.module) and entry.module != artifact.module ->
        next_state =
          state
          |> runtime_put(%{
            entry
            | blocked_reason: {:module_mismatch, entry.module, artifact.module}
          })

        {{:error, {:module_mismatch, entry.module, artifact.module}}, next_state}

      old_code?(artifact.module) and not :code.soft_purge(artifact.module) ->
        lingering_pids = lingering_pids(artifact.module)

        next_state =
          state
          |> runtime_put(%{
            entry
            | blocked_reason: :old_code_in_use,
              lingering_pids: lingering_pids
          })

        {{:blocked, %{reason: :old_code_in_use, module: artifact.module, pids: lingering_pids}},
         next_state}

      true ->
        case :code.load_binary(
               artifact.module,
               String.to_charlist(Atom.to_string(artifact.module)),
               artifact.beam
             ) do
          {:module, module} ->
            next_state =
              state
              |> runtime_put(%{
                entry
                | module: module,
                  source_digest: artifact.source_digest,
                  blocked_reason: nil,
                  lingering_pids: []
              })

            {{:ok, %{id: id, module: module, status: :applied}}, next_state}

          {:error, reason} ->
            next_state = state |> runtime_put(%{entry | blocked_reason: reason})
            {{:error, reason}, next_state}
        end
    end
  end

  defp reset_runtime_modules_internal(%State{} = state) do
    blocked =
      Enum.flat_map(Map.values(state.runtime_entries), fn
        %RuntimeEntry{module: module, id: id} when is_atom(module) ->
          unload_block_reason(id, module)

        _entry ->
          []
      end)

    case blocked do
      [] ->
        Enum.each(Map.values(state.runtime_entries), fn
          %RuntimeEntry{module: module} when is_atom(module) -> unload_module(module)
          _entry -> :ok
        end)

        {:ok, %State{state | runtime_entries: %{}}}

      blocked_modules ->
        {{:blocked, %{reason: :old_code_in_use, modules: blocked_modules}}, state}
    end
  end

  defp update_compile_diagnostics(%State{} = state, kind, id, diagnostics) do
    {updated, next_state} = reduce(state, {:record_compile, kind, id, diagnostics})
    _ = updated
    next_state
  end

  defp runtime_put(%State{} = state, %RuntimeEntry{id: id} = entry) do
    put_in(state.runtime_entries[id], entry)
  end

  defp list_entries(kind) do
    kind
    |> list_kind()
    |> Enum.map(&elem(&1, 1))
  end

  defp seeded_driver_draft(id) do
    model = DriverSource.default_model(id)

    source =
      DriverSource.to_source(DriverSource.module_from_name!(model.module_name), model)

    %DriverDraft{
      id: id,
      source: source,
      model: model,
      sync_state: :synced
    }
  end

  defp seeded_machine_draft(id) do
    %{model: model, source: source, sync_state: sync_state, sync_diagnostics: sync_diagnostics} =
      case DemoSeed.machine_draft(id) do
        nil ->
          model = machine_seed_model(id)

          %{
            model: model,
            source: MachineSource.to_source(model),
            sync_state: :synced,
            sync_diagnostics: []
          }

        draft ->
          draft
      end

    %MachineDraft{
      id: id,
      source: source,
      model: model,
      sync_state: sync_state,
      sync_diagnostics: sync_diagnostics
    }
  end

  defp machine_seed_model("inspection_cell") do
    MachineSource.default_model("inspection_cell")
    |> Map.put(:meaning, "Inspection cell coordinator")
    |> Map.put(:requests, [%{name: "start"}, %{name: "reject"}, %{name: "reset"}])
    |> Map.put(:signals, [%{name: "started"}, %{name: "rejected"}, %{name: "faulted"}])
    |> Map.put(:transitions, [
      %{
        source: "idle",
        family: "request",
        trigger: "start",
        destination: "running",
        meaning: nil
      },
      %{
        source: "running",
        family: "request",
        trigger: "reject",
        destination: "faulted",
        meaning: nil
      },
      %{source: "faulted", family: "request", trigger: "reset", destination: "idle", meaning: nil}
    ])
  end

  defp machine_seed_model("palletizer_cell") do
    MachineSource.default_model("palletizer_cell")
    |> Map.put(:meaning, "Palletizer cell coordinator")
    |> Map.put(:requests, [%{name: "arm"}, %{name: "stop"}, %{name: "reset"}])
    |> Map.put(:signals, [%{name: "armed"}, %{name: "stopped"}, %{name: "faulted"}])
    |> Map.put(:transitions, [
      %{source: "idle", family: "request", trigger: "arm", destination: "running", meaning: nil},
      %{source: "running", family: "request", trigger: "stop", destination: "idle", meaning: nil},
      %{source: "faulted", family: "request", trigger: "reset", destination: "idle", meaning: nil}
    ])
  end

  defp machine_seed_model(id), do: MachineSource.default_model(id)

  defp seeded_topology_draft(id) do
    %{model: model, source: source, sync_state: sync_state, sync_diagnostics: sync_diagnostics} =
      case DemoSeed.topology_draft(id) do
        nil ->
          model = TopologySource.default_model(id)

          %{
            model: model,
            source: TopologySource.to_source(model),
            sync_state: :synced,
            sync_diagnostics: []
          }

        draft ->
          draft
      end

    %TopologyDraft{
      id: id,
      source: source,
      model: model,
      sync_state: sync_state,
      sync_diagnostics: sync_diagnostics
    }
  end

  defp seeded_sequence_draft(id, state) do
    source =
      SequenceSource.default_source(
        id,
        topology_module_name: default_topology_module_name(state)
      )

    {model, sync_state, sync_diagnostics} =
      case SequenceSource.from_source(source) do
        {:ok, model} -> {model, :synced, []}
        {:error, diagnostics} -> {nil, :unsupported, diagnostics}
      end

    %SequenceDraft{
      id: id,
      source: source,
      model: model,
      sync_state: sync_state,
      sync_diagnostics: sync_diagnostics
    }
  end

  defp seeded_hardware_config_draft do
    %HardwareConfig{} = config = DemoSeed.default_hardware_config()

    %HardwareConfigDraft{
      id: @hardware_config_entry_id,
      source: HardwareConfigSource.to_source(config),
      model: config,
      sync_state: :synced,
      sync_diagnostics: []
    }
  end

  defp seeded_hmi_surface_draft(id, source_module) do
    %HmiSurfaceDraft{
      id: id,
      source: "",
      source_module: source_module,
      model: nil,
      sync_state: :unsupported,
      sync_diagnostics: []
    }
  end

  defp default_topology_module_name(%State{} = state) do
    state
    |> preferred_topology_entry()
    |> topology_entry_module_name()
    |> case do
      module_name when is_binary(module_name) -> module_name
      nil -> "Ogol.Generated.Topologies.PackagingLine"
    end
  end

  defp preferred_topology_entry(%State{} = state) do
    fetch_entry(state, :topology, topology_default_id()) ||
      state
      |> entries_for_kind(:topology)
      |> Map.values()
      |> Enum.sort_by(&draft_id/1)
      |> List.first()
  end

  defp topology_entry_module_name(%{model: %{module_name: module_name}})
       when is_binary(module_name),
       do: module_name

  defp topology_entry_module_name(%{source: source}) when is_binary(source) do
    case TopologySource.module_from_source(source) do
      {:ok, module} -> Atom.to_string(module) |> String.trim_leading("Elixir.")
      {:error, _reason} -> nil
    end
  end

  defp topology_entry_module_name(_entry), do: nil

  defp machine_default_ids do
    @default_machine_ids ++ DemoSeed.machine_ids()
  end

  defp topology_default_ids do
    @default_topology_ids ++ DemoSeed.topology_ids()
  end

  defp next_available_id(%State{} = state, kind, prefix) do
    existing_ids =
      state
      |> entries_for_kind(kind)
      |> Map.values()
      |> Enum.map(&draft_id/1)
      |> MapSet.new()

    next_available_id(existing_ids, prefix)
  end

  defp next_available_id(existing_ids, prefix) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "#{prefix}#{index}"
      if MapSet.member?(existing_ids, candidate), do: nil, else: candidate
    end)
  end

  defp normalize_create_id(nil), do: :auto
  defp normalize_create_id(id), do: id

  defp runtime_id(kind, id) when is_atom(kind), do: {kind, to_string(id)}

  defp entries_for_kind(%State{} = state, kind) do
    Map.get(state.entries, kind, %{})
  end

  defp initial_entries do
    %{
      driver: default_entries(:driver),
      machine: default_entries(:machine),
      topology: default_entries(:topology),
      sequence: default_entries(:sequence),
      hardware_config: default_entries(:hardware_config),
      hmi_surface: default_entries(:hmi_surface)
    }
  end

  defp put_entry(%State{} = state, kind, id, entry) do
    next_entries =
      state.entries
      |> Map.get(kind, %{})
      |> Map.put(id, entry)

    put_in(state.entries[kind], next_entries)
  end

  defp fetch_entry(%State{} = state, kind, id) do
    state
    |> entries_for_kind(kind)
    |> Map.get(id)
  end

  defp fetch_runtime_entry(%State{} = state, id) do
    Map.get(state.runtime_entries, id)
  end

  defp config_from_source(source) when is_binary(source) do
    case HardwareConfigSource.from_source(source) do
      {:ok, %HardwareConfig{} = config} -> config
      :unsupported -> nil
    end
  end

  defp default_entries(kind) do
    kind
    |> seeded_defaults()
    |> Map.new(fn entry -> {draft_id(entry), entry} end)
  end

  defp seeded_defaults(:driver), do: [seeded_driver_draft(@default_driver_id)]
  defp seeded_defaults(:machine), do: Enum.map(machine_default_ids(), &seeded_machine_draft/1)
  defp seeded_defaults(:topology), do: Enum.map(topology_default_ids(), &seeded_topology_draft/1)
  defp seeded_defaults(:sequence), do: []
  defp seeded_defaults(:hardware_config), do: [seeded_hardware_config_draft()]
  defp seeded_defaults(:hmi_surface), do: []

  defp seeded_entry(_state, :driver, id), do: seeded_driver_draft(id)
  defp seeded_entry(_state, :machine, id), do: seeded_machine_draft(id)
  defp seeded_entry(_state, :topology, id), do: seeded_topology_draft(id)
  defp seeded_entry(state, :sequence, id), do: seeded_sequence_draft(id, state)
  defp seeded_entry(_state, :hardware_config, _id), do: seeded_hardware_config_draft()

  defp seeded_entry(_state, :hmi_surface, id),
    do: seeded_hmi_surface_draft(id, default_hmi_module(id))

  defp kind_prefix(:driver), do: "driver_"
  defp kind_prefix(:machine), do: "machine_"
  defp kind_prefix(:topology), do: "topology_"
  defp kind_prefix(:sequence), do: "sequence_"
  defp kind_prefix(:hardware_config), do: "hardware_config_"
  defp kind_prefix(:hmi_surface), do: "surface_"

  defp maybe_reset_compile_diagnostics(draft, false), do: draft

  defp maybe_reset_compile_diagnostics(%{build_diagnostics: _} = draft, true) do
    %{draft | build_diagnostics: []}
  end

  defp maybe_reset_compile_diagnostics(%{compile_diagnostics: _} = draft, true) do
    %{draft | compile_diagnostics: []}
  end

  defp put_compile_diagnostics(%{build_diagnostics: _} = draft, diagnostics) do
    %{draft | build_diagnostics: diagnostics}
  end

  defp put_compile_diagnostics(%{compile_diagnostics: _} = draft, diagnostics) do
    %{draft | compile_diagnostics: normalize_compile_diagnostics(diagnostics)}
  end

  defp maybe_clear_loaded_revision(%State{} = state, true), do: clear_loaded_revision(state)
  defp maybe_clear_loaded_revision(%State{} = state, false), do: state

  defp clear_loaded_revision(%State{loaded_revision: %LoadedRevision{} = loaded_revision} = state) do
    %State{state | loaded_revision: %{loaded_revision | revision: nil}}
  end

  defp clear_loaded_revision(%State{} = state), do: state

  defp draft_id(%{id: id}) when is_binary(id), do: id
  defp draft_id(%{surface_id: id}) when is_binary(id), do: id

  defp default_hmi_module(id) when is_binary(id) do
    Module.concat([Ogol, HMI, Surfaces, StudioDrafts, Macro.camelize(id)])
  end

  defp broadcast_workspace_event(operation, reply, %State{} = state) do
    Bus.broadcast(
      Bus.workspace_topic(),
      {:workspace_updated, operation, reply, workspace_session(state)}
    )
  end

  defp workspace_session(%State{loaded_revision: %LoadedRevision{} = loaded_revision}) do
    %{
      app_id: loaded_revision.app_id,
      revision: loaded_revision.revision,
      inventory: loaded_revision.inventory
    }
  end

  defp workspace_session(%State{}), do: %{app_id: nil, revision: nil, inventory: []}

  defp old_code?(module) when is_atom(module), do: :erlang.check_old_code(module)
  defp old_code?(_module), do: false

  defp lingering_pids(module) do
    Process.list()
    |> Enum.filter(fn pid ->
      try do
        :erlang.check_process_code(pid, module) == true
      catch
        :error, _ -> false
      end
    end)
  end

  defp unload_block_reason(id, module) do
    module
    |> lingering_pids()
    |> case do
      [] ->
        []

      pids ->
        [%{id: id, module: module, pids: pids}]
    end
  end

  defp unload_module(module) when is_atom(module) do
    _ = :code.soft_purge(module)
    _ = :code.purge(module)
    _ = :code.delete(module)
    :ok
  end

  defp normalize_compile_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.map(&format_compile_diagnostic/1)
  end

  defp format_compile_diagnostic(%{message: message}) when is_binary(message), do: message
  defp format_compile_diagnostic(other) when is_binary(other), do: other
  defp format_compile_diagnostic(other), do: inspect(other)
end
