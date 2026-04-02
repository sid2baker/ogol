defmodule Ogol.Session.Workspace do
  @moduledoc false

  alias Ogol.Driver.Source, as: DriverSource
  alias Ogol.HMI.Surface
  alias Ogol.Hardware.Config, as: HardwareConfig
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.Machine.Form, as: MachineForm
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Session.DemoSeed
  alias Ogol.Topology.Source, as: TopologySource

  @default_driver_id "packaging_outputs"
  @hardware_config_entry_id "hardware_config"
  @default_machine_ids ["packaging_line", "inspection_cell", "palletizer_cell"]
  @default_topology_ids ["packaging_line", "inspection_cell", "palletizer_cell"]

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

  defmodule SourceDraft do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            source: String.t(),
            source_module: module() | nil,
            model: term() | nil,
            sync_state: :synced | :partial | :unsupported,
            sync_diagnostics: [term()]
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

  @type kind :: :driver | :machine | :topology | :sequence | :hardware_config | :hmi_surface

  @type operation ::
          {:reset_kind, kind()}
          | {:replace_entries, kind(), [term()]}
          | {:create_entry, kind(), String.t() | :auto}
          | {:delete_entry, kind(), String.t()}
          | {:save_source, kind(), String.t(), String.t(), map() | nil, atom(), [term()]}
          | {:save_hmi_surface_source, String.t(), String.t(), module(), Surface.t() | nil,
             atom(), [term()]}
          | {:put_loaded_revision, String.t() | nil, String.t() | nil,
             [LoadedRevision.inventory_item()]}
          | {:set_loaded_revision_id, String.t() | nil}
          | :reset_loaded_revision

  def new, do: %__MODULE__{entries: initial_entries()}

  def driver_default_id, do: @default_driver_id
  def hardware_config_entry_id, do: @hardware_config_entry_id
  def machine_default_id, do: hd(machine_default_ids())
  def topology_default_id, do: hd(topology_default_ids())

  @spec apply_operation(t(), operation()) :: {:ok, t(), term(), [operation()]}
  def apply_operation(%__MODULE__{} = state, operation) do
    {reply, next_state, operations} = reduce(state, operation)
    {:ok, next_state, reply, operations}
  end

  @spec reduce(t(), operation()) :: {term(), t(), [operation()]}
  def reduce(%__MODULE__{} = state, operation) do
    case operation do
      {:reset_kind, kind} ->
        next_state =
          state
          |> put_in([Access.key(:entries), Access.key(kind)], default_entries(kind))
          |> clear_loaded_revision()

        reply_with_operations(:ok, next_state, operation)

      {:replace_entries, kind, drafts} ->
        kind_entries =
          drafts
          |> Map.new(fn draft -> {draft_id(draft), draft} end)

        next_state =
          state
          |> put_in([Access.key(:entries), Access.key(kind)], kind_entries)
          |> clear_loaded_revision()

        reply_with_operations(:ok, next_state, operation)

      {:create_entry, kind, :auto} ->
        id = next_available_id(state, kind, kind_prefix(kind))
        reduce(state, {:create_entry, kind, id})

      {:create_entry, kind, id} when is_binary(id) ->
        entry = seeded_entry(state, kind, id)

        {entry,
         state
         |> put_entry(kind, id, entry)
         |> clear_loaded_revision(), [operation]}

      {:delete_entry, kind, id} when is_binary(id) ->
        next_state =
          state
          |> delete_entry(kind, id)
          |> clear_loaded_revision()

        reply_with_operations(:ok, next_state, operation)

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

        reply_with_operations(updated, next_state, operation)

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

        reply_with_operations(updated, next_state, operation)

      {:put_loaded_revision, app_id, revision, inventory} ->
        loaded_revision = %LoadedRevision{
          app_id: app_id,
          revision: revision,
          inventory: inventory
        }

        reply_with_operations(
          loaded_revision,
          %__MODULE__{state | loaded_revision: loaded_revision},
          operation
        )

      {:set_loaded_revision_id, revision} ->
        loaded_revision =
          state.loaded_revision
          |> Kernel.||(%LoadedRevision{})
          |> Map.put(:revision, revision)

        reply_with_operations(
          loaded_revision,
          %__MODULE__{state | loaded_revision: loaded_revision},
          operation
        )

      :reset_loaded_revision ->
        reply_with_operations(:ok, %__MODULE__{state | loaded_revision: nil}, operation)
    end
  end

  def list_kind(%__MODULE__{} = state, kind) when is_atom(kind) do
    entries =
      state.entries
      |> Map.get(kind, %{})
      |> Enum.sort_by(fn {id, _entry} -> id end)

    entries
  end

  def list_entries(%__MODULE__{} = state, kind),
    do: Enum.map(list_kind(state, kind), &elem(&1, 1))

  def fetch(%__MODULE__{} = state, kind, id) when is_atom(kind) and is_binary(id),
    do: state |> Map.get(:entries, %{}) |> Map.get(kind, %{}) |> Map.get(id)

  def current_hardware_config(%__MODULE__{} = state) do
    case fetch(state, :hardware_config, @hardware_config_entry_id) do
      %{model: %HardwareConfig{} = config} -> config
      %{source: source} when is_binary(source) -> config_from_source(source)
      _other -> nil
    end
  end

  def loaded_inventory(%__MODULE__{} = state) do
    case state.loaded_revision do
      %LoadedRevision{inventory: inventory} -> inventory
      nil -> []
    end
  end

  def loaded_revision(%__MODULE__{} = state), do: state.loaded_revision

  def workspace_session(%__MODULE__{loaded_revision: %LoadedRevision{} = loaded_revision}) do
    %{
      app_id: loaded_revision.app_id,
      revision: loaded_revision.revision,
      inventory: loaded_revision.inventory
    }
  end

  def workspace_session(%__MODULE__{}), do: %{app_id: nil, revision: nil, inventory: []}

  defp seeded_driver_draft(id) do
    model = DriverSource.default_model(id)

    source =
      DriverSource.to_source(DriverSource.module_from_name!(model.module_name), model)

    %SourceDraft{
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

    %SourceDraft{
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

    %SourceDraft{
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

    %SourceDraft{
      id: id,
      source: source,
      model: model,
      sync_state: sync_state,
      sync_diagnostics: sync_diagnostics
    }
  end

  defp seeded_hardware_config_draft do
    %HardwareConfig{} = config = DemoSeed.default_hardware_config()

    %SourceDraft{
      id: @hardware_config_entry_id,
      source: HardwareConfigSource.to_source(config),
      model: config,
      sync_state: :synced,
      sync_diagnostics: []
    }
  end

  defp seeded_hmi_surface_draft(id, source_module) do
    %SourceDraft{
      id: id,
      source: "",
      source_module: source_module,
      model: nil,
      sync_state: :unsupported,
      sync_diagnostics: []
    }
  end

  defp default_topology_module_name(%__MODULE__{} = state) do
    state
    |> preferred_topology_entry()
    |> topology_entry_module_name()
    |> case do
      module_name when is_binary(module_name) -> module_name
      nil -> "Ogol.Generated.Topologies.PackagingLine"
    end
  end

  defp preferred_topology_entry(%__MODULE__{} = state) do
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

  defp next_available_id(%__MODULE__{} = state, kind, prefix) do
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

  defp entries_for_kind(%__MODULE__{} = state, kind) do
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

  defp put_entry(%__MODULE__{} = state, kind, id, entry) do
    next_entries =
      state.entries
      |> Map.get(kind, %{})
      |> Map.put(id, entry)

    put_in(state.entries[kind], next_entries)
  end

  defp delete_entry(%__MODULE__{} = state, kind, id) do
    next_entries =
      state.entries
      |> Map.get(kind, %{})
      |> Map.delete(id)

    put_in(state.entries[kind], next_entries)
  end

  defp fetch_entry(%__MODULE__{} = state, kind, id) do
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

  defp maybe_clear_loaded_revision(%__MODULE__{} = state, true), do: clear_loaded_revision(state)
  defp maybe_clear_loaded_revision(%__MODULE__{} = state, false), do: state

  defp clear_loaded_revision(
         %__MODULE__{loaded_revision: %LoadedRevision{} = loaded_revision} = state
       ) do
    %__MODULE__{state | loaded_revision: %{loaded_revision | revision: nil}}
  end

  defp clear_loaded_revision(%__MODULE__{} = state), do: state

  defp draft_id(%{id: id}) when is_binary(id), do: id
  defp draft_id(%{surface_id: id}) when is_binary(id), do: id

  defp default_hmi_module(id) when is_binary(id) do
    Module.concat(["Ogol", "HMI", "Surface", "StudioDrafts", Macro.camelize(id)])
  end

  defp reply_with_operations(reply, %__MODULE__{} = next_state, operation) do
    {reply, next_state, [operation]}
  end
end
