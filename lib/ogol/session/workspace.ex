defmodule Ogol.Session.Workspace do
  @moduledoc false

  alias Ogol.HMI.Surface
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Topology.Source, as: TopologySource

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
              machine: %{},
              topology: %{},
              sequence: %{},
              hardware_config: %{},
              hmi_surface: %{}
            },
            loaded_revision: nil

  @type kind :: :machine | :topology | :sequence | :hardware_config | :hmi_surface

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

  def new, do: %__MODULE__{}

  @spec apply_operation(t(), operation()) :: {:ok, t(), term(), [operation()]} | :error
  def apply_operation(%__MODULE__{} = state, operation) do
    case reduce(state, operation) do
      :error -> :error
      {reply, next_state, operations} -> {:ok, next_state, reply, operations}
    end
  end

  @spec reduce(t(), operation()) :: {term(), t(), [operation()]} | :error
  def reduce(%__MODULE__{} = state, operation) do
    case operation do
      {:reset_kind, kind} ->
        next_state =
          state
          |> put_in([Access.key(:entries), Access.key(kind)], %{})
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
        entry = new_entry(state, kind, id)

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
        with {:ok, entry} <- fetch_existing_entry(state, kind, id) do
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
        end

      {:save_hmi_surface_source, id, source, source_module, model, sync_state, sync_diagnostics} ->
        with {:ok, entry} <- fetch_existing_entry(state, :hmi_surface, id) do
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
        end

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

  def hardware_config_model(%__MODULE__{} = state, id) when is_binary(id) do
    case fetch(state, :hardware_config, id) do
      %{model: config} when is_struct(config) -> config
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

  defp new_machine_draft(id) do
    model = Ogol.Machine.Form.default_model(id)
    source = MachineSource.to_source(model)

    %SourceDraft{
      id: id,
      source: source,
      model: model,
      sync_state: :synced,
      sync_diagnostics: []
    }
  end

  defp new_topology_draft(id) do
    model = TopologySource.default_model(id)
    source = TopologySource.to_source(model)

    %SourceDraft{
      id: id,
      source: source,
      model: model,
      sync_state: :synced,
      sync_diagnostics: []
    }
  end

  defp new_sequence_draft(id, state) do
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

  defp new_hardware_config_draft(id) when is_binary(id) do
    case HardwareConfigSource.default_model(id) do
      model when is_struct(model) ->
        %SourceDraft{
          id: id,
          source: HardwareConfigSource.to_source(model),
          model: model,
          sync_state: :synced,
          sync_diagnostics: []
        }

      nil ->
        %SourceDraft{
          id: id,
          source: "",
          model: nil,
          sync_state: :unsupported,
          sync_diagnostics: []
        }
    end
  end

  defp new_hmi_surface_draft(id, source_module) do
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
      nil -> "Ogol.Generated.Topologies.Topology1"
    end
  end

  defp preferred_topology_entry(%__MODULE__{} = state) do
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
      {:ok, config} when is_struct(config) -> config
      :unsupported -> nil
    end
  end

  defp new_entry(_state, :machine, id), do: new_machine_draft(id)
  defp new_entry(_state, :topology, id), do: new_topology_draft(id)
  defp new_entry(state, :sequence, id), do: new_sequence_draft(id, state)
  defp new_entry(_state, :hardware_config, id), do: new_hardware_config_draft(id)

  defp new_entry(_state, :hmi_surface, id),
    do: new_hmi_surface_draft(id, default_hmi_module(id))

  defp fetch_existing_entry(%__MODULE__{} = state, kind, id) do
    case fetch_entry(state, kind, id) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

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
