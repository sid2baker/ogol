defmodule Ogol.Studio.WorkspaceStore do
  @moduledoc false

  use GenServer

  alias Ogol.Driver.Source, as: DriverSource
  alias Ogol.Runtime.Bus
  alias Ogol.HMI.Surface
  alias Ogol.Hardware.Config, as: HardwareConfig
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.Machine.Form, as: MachineForm
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Studio.DemoSeed
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
            sync_diagnostics: [term()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: []
    ]
  end

  defmodule MachineDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: []
    ]
  end

  defmodule TopologyDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: []
    ]
  end

  defmodule SequenceDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: map() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: []
    ]
  end

  defmodule HardwareConfigDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            model: HardwareConfig.t() | nil,
            sync_state: :synced | :unsupported,
            sync_diagnostics: [String.t()]
          }

    defstruct [
      :id,
      :source,
      :model,
      sync_state: :synced,
      sync_diagnostics: []
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
      sync_state: :unsupported,
      sync_diagnostics: []
    ]
  end

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            entries: %{optional(atom()) => %{optional(String.t()) => term()}},
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
              loaded_revision: nil
  end

  @type kind :: :driver | :machine | :topology | :sequence | :hardware_config | :hmi_surface

  @type operation ::
          {:reset_kind, kind()}
          | {:replace_entries, kind(), [term()]}
          | {:create_entry, kind(), String.t() | :auto}
          | {:save_source, kind(), String.t(), String.t(), map() | nil, atom(), [term()]}
          | {:save_hmi_surface_source, String.t(), String.t(), module(), Surface.t() | nil,
             atom(), [term()]}
          | {:put_loaded_revision, String.t() | nil, String.t() | nil,
             [LoadedRevision.inventory_item()]}
          | {:set_loaded_revision_id, String.t() | nil}
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

  @spec apply_operation(State.t(), operation()) :: {:ok, State.t(), term()}
  def apply_operation(%State{} = state, operation) do
    {reply, next_state} = reduce(state, operation)
    {:ok, next_state, reply}
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
    replace_hmi_surfaces(Ogol.HMI.Surface.Defaults.drafts_from_workspace())
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

  def reset_loaded_revision do
    dispatch(:reset_loaded_revision)
  end

  @impl true
  def init(_opts) do
    {:ok, %State{entries: initial_entries()}}
  end

  @impl true
  def handle_call({:dispatch, operation}, _from, %State{} = state) do
    {:ok, next_state, reply} = apply_operation(state, operation)
    broadcast_workspace_event(operation, reply, next_state)
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

  def handle_call(:loaded_revision, _from, %State{} = state) do
    {:reply, state.loaded_revision, state}
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
    MachineForm.default_model("inspection_cell")
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
    MachineForm.default_model("palletizer_cell")
    |> Map.put(:meaning, "Palletizer cell coordinator")
    |> Map.put(:requests, [%{name: "arm"}, %{name: "stop"}, %{name: "reset"}])
    |> Map.put(:signals, [%{name: "armed"}, %{name: "stopped"}, %{name: "faulted"}])
    |> Map.put(:transitions, [
      %{source: "idle", family: "request", trigger: "arm", destination: "running", meaning: nil},
      %{source: "running", family: "request", trigger: "stop", destination: "idle", meaning: nil},
      %{source: "faulted", family: "request", trigger: "reset", destination: "idle", meaning: nil}
    ])
  end

  defp machine_seed_model(id), do: MachineForm.default_model(id)

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

  defp maybe_clear_loaded_revision(%State{} = state, true), do: clear_loaded_revision(state)
  defp maybe_clear_loaded_revision(%State{} = state, false), do: state

  defp clear_loaded_revision(%State{loaded_revision: %LoadedRevision{} = loaded_revision} = state) do
    %State{state | loaded_revision: %{loaded_revision | revision: nil}}
  end

  defp clear_loaded_revision(%State{} = state), do: state

  defp draft_id(%{id: id}) when is_binary(id), do: id
  defp draft_id(%{surface_id: id}) when is_binary(id), do: id

  defp default_hmi_module(id) when is_binary(id) do
    Module.concat(["Ogol", "HMI", "Surface", "StudioDrafts", Macro.camelize(id)])
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
end
