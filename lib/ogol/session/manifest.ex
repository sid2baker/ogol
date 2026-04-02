defmodule Ogol.Session.Manifest do
  @moduledoc false

  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Session.Data
  alias Ogol.Session.Workspace
  alias Ogol.Studio.Build
  alias Ogol.Session
  alias Ogol.Topology.Source, as: TopologySource

  @type kind :: Workspace.kind()

  defmodule Entry do
    @moduledoc false

    @type t :: %__MODULE__{
            kind: Workspace.kind(),
            id: String.t(),
            artifact_name: String.t(),
            module: module() | nil,
            source_digest: String.t(),
            provenance: %{cell_id: String.t()}
          }

    defstruct [:kind, :id, :artifact_name, :module, :source_digest, :provenance]
  end

  defmodule Diff do
    @moduledoc false

    @type item :: %{current: Entry.t() | nil, active: Entry.t() | nil}

    @type t :: %__MODULE__{
            added: [item()],
            changed: [item()],
            unchanged: [item()],
            removed: [item()]
          }

    defstruct added: [], changed: [], unchanged: [], removed: []
  end

  @spec current() :: [Entry.t()]
  def current do
    Session.get_data()
    |> Data.workspace()
    |> entries_for_workspace()
  end

  @spec entries_for_workspace(Workspace.t()) :: [Entry.t()]
  def entries_for_workspace(%Workspace{} = workspace) do
    [
      entries_for_kind(:machine, Workspace.list_entries(workspace, :machine)),
      entries_for_kind(:topology, Workspace.list_entries(workspace, :topology)),
      entries_for_kind(:sequence, Workspace.list_entries(workspace, :sequence)),
      entries_for_kind(:hardware_config, Workspace.list_entries(workspace, :hardware_config)),
      entries_for_kind(:hmi_surface, Workspace.list_entries(workspace, :hmi_surface))
    ]
    |> List.flatten()
    |> Enum.sort_by(fn %Entry{kind: kind, id: id} -> {kind, id} end)
  end

  @spec diff([Entry.t()], [Entry.t()]) :: Diff.t()
  def diff(current_entries, active_entries)
      when is_list(current_entries) and is_list(active_entries) do
    current_by_key = Map.new(current_entries, &{{&1.kind, &1.id}, &1})
    active_by_key = Map.new(active_entries, &{{&1.kind, &1.id}, &1})

    keys =
      current_by_key
      |> Map.keys()
      |> Kernel.++(Map.keys(active_by_key))
      |> Enum.uniq()
      |> Enum.sort()

    Enum.reduce(keys, %Diff{}, fn key, %Diff{} = acc ->
      current = Map.get(current_by_key, key)
      active = Map.get(active_by_key, key)

      cond do
        is_nil(active) ->
          %{acc | added: [%{current: current, active: nil} | acc.added]}

        is_nil(current) ->
          %{acc | removed: [%{current: nil, active: active} | acc.removed]}

        entry_equal?(current, active) ->
          %{acc | unchanged: [%{current: current, active: active} | acc.unchanged]}

        true ->
          %{acc | changed: [%{current: current, active: active} | acc.changed]}
      end
    end)
    |> reverse_groups()
  end

  defp reverse_groups(%Diff{} = diff) do
    %Diff{
      added: Enum.reverse(diff.added),
      changed: Enum.reverse(diff.changed),
      unchanged: Enum.reverse(diff.unchanged),
      removed: Enum.reverse(diff.removed)
    }
  end

  defp entry_equal?(%Entry{} = current, %Entry{} = active) do
    current.module == active.module and
      current.source_digest == active.source_digest and
      current.provenance == active.provenance
  end

  defp entries_for_kind(kind, drafts) when is_list(drafts) do
    Enum.map(drafts, &entry_for_draft(kind, &1))
  end

  defp entry_for_draft(:machine, %{id: id, source: source}) do
    entry(:machine, id, source, fn -> MachineSource.module_from_source(source) end)
  end

  defp entry_for_draft(:topology, %{id: id, source: source}) do
    entry(:topology, id, source, fn -> TopologySource.module_from_source(source) end)
  end

  defp entry_for_draft(:sequence, %{id: id, source: source}) do
    entry(:sequence, id, source, fn -> SequenceSource.module_from_source(source) end)
  end

  defp entry_for_draft(:hardware_config, %{id: id, source: source}) do
    entry(:hardware_config, id, source, fn -> HardwareConfigSource.module_from_source(source) end)
  end

  defp entry_for_draft(:hmi_surface, %{id: id, source: source, source_module: source_module}) do
    %Entry{
      kind: :hmi_surface,
      id: id,
      artifact_name: id,
      module: source_module,
      source_digest: Build.digest(source || ""),
      provenance: %{cell_id: id}
    }
  end

  defp entry(kind, id, source, module_fun) do
    module =
      case module_fun.() do
        {:ok, resolved_module} -> resolved_module
        _ -> nil
      end

    %Entry{
      kind: kind,
      id: id,
      artifact_name: id,
      module: module,
      source_digest: Build.digest(source || ""),
      provenance: %{cell_id: id}
    }
  end
end
