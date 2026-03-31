defmodule Ogol.HMI.StudioWorkspace do
  @moduledoc false

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.BindingRef
  alias Ogol.HMI.Surfaces.{OperationsOverview, OperationsStation}
  alias Ogol.Machine.Info
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Topology.Model
  alias Ogol.Topology.Registry
  alias Ogol.Topology.Source, as: TopologySource

  defmodule Workspace do
    @moduledoc false

    defstruct [:topology_id, :title, :summary, cells: []]
  end

  defmodule Cell do
    @moduledoc false

    defstruct [
      :surface_id,
      :kind,
      :topology_id,
      :machine_id,
      :title,
      :summary,
      :definition,
      :source_module
    ]
  end

  def active_workspace do
    with %{module: module, root: topology_id} <- Registry.active_topology(),
         true <- function_exported?(module, :__ogol_topology__, 0),
         %Model{} = topology <- module.__ogol_topology__() do
      {:ok,
       %Workspace{
         topology_id: topology_id,
         title: topology_title(topology),
         summary: "Studio Cells for the currently active topology runtime.",
         cells: build_cells(topology, %{})
       }}
    else
      nil -> {:error, :no_active_topology}
      false -> {:error, :invalid_active_topology}
      _ -> {:error, :invalid_active_topology}
    end
  end

  def workspace_from_current_draft do
    case select_draft_topology(WorkspaceStore.list_topologies()) do
      %{model: model} = draft ->
        topology =
          topology_from_bundle_model(model) ||
            case TopologySource.from_source(draft.source) do
              {:ok, parsed_model} -> parsed_model
              {:error, _diagnostics} -> nil
            end

        if topology do
          machine_titles =
            WorkspaceStore.list_machines()
            |> Map.new(fn draft -> {draft.id, machine_draft_title(draft)} end)

          {:ok,
           workspace_from_topology(topology,
             summary: "Studio Cells for the current draft bundle.",
             machine_titles: machine_titles
           )}
        else
          {:error, :no_active_topology}
        end

      nil ->
        {:error, :no_active_topology}
    end
  end

  def workspace_from_topology(%Model{} = topology, opts \\ []) do
    machine_titles = Keyword.get(opts, :machine_titles, %{})

    summary =
      Keyword.get(opts, :summary, "Studio Cells for the currently active topology runtime.")

    %Workspace{
      topology_id: topology.root,
      title: topology_title(topology),
      summary: summary,
      cells: build_cells(topology, machine_titles)
    }
  end

  defp select_draft_topology(drafts) do
    Enum.find(drafts, &(&1.id == WorkspaceStore.topology_default_id())) ||
      List.first(Enum.sort_by(drafts, & &1.id))
  end

  defp build_cells(%Model{} = topology, machine_titles) do
    [
      overview_cell(topology)
      | Enum.map(topology.machines, &station_cell(topology, &1, machine_titles))
    ]
  end

  defp overview_cell(%Model{} = topology) do
    base = Surface.definition(OperationsOverview)
    topology_id = to_string(topology.root)

    definition =
      %{
        base
        | id: overview_surface_id(topology_id),
          title: "#{topology_title(topology)} Overview",
          summary: "Topology-wide operations surface for #{topology_title(topology)}.",
          bindings: [
            %BindingRef{
              name: :runtime_summary,
              source: {:topology_runtime_summary, topology.root}
            },
            %BindingRef{name: :alarm_summary, source: {:topology_alarm_summary, topology.root}},
            %BindingRef{name: :attention_lane, source: {:topology_attention_lane, topology.root}},
            %BindingRef{
              name: :machine_registry,
              source: {:topology_machine_registry, topology.root}
            },
            %BindingRef{name: :event_stream, source: {:topology_event_stream, topology.root}},
            %BindingRef{name: :ops_links, source: {:topology_links, topology.root}}
          ]
      }

    %Cell{
      surface_id: overview_surface_id(topology_id),
      kind: :overview,
      topology_id: topology_id,
      title: definition.title,
      summary: definition.summary,
      definition: definition,
      source_module: overview_source_module(topology_id)
    }
  end

  defp station_cell(%Model{} = topology, machine, machine_titles) do
    machine_name = machine_name(machine)
    machine_id = to_string(machine_name)
    topology_id = to_string(topology.root)
    machine_title = machine_title(machine_id, machine, machine_titles)
    base = Surface.definition(OperationsStation)

    definition =
      %{
        base
        | id: station_surface_id(topology_id, machine_id),
          title: "#{machine_title} Station",
          summary:
            "Focused operator surface for #{machine_title} inside #{topology_title(topology)}.",
          bindings: station_bindings(machine_name, machine_id)
      }

    %Cell{
      surface_id: station_surface_id(topology_id, machine_id),
      kind: :station,
      topology_id: topology_id,
      machine_id: machine_id,
      title: definition.title,
      summary: definition.summary,
      definition: definition,
      source_module: station_source_module(topology_id, machine_id)
    }
  end

  defp station_bindings(machine_name, machine_id) do
    [
      %BindingRef{name: :station_status, source: {:machine_status, machine_name}},
      %BindingRef{name: :station_alarm_summary, source: {:machine_alarm_summary, machine_name}},
      %BindingRef{name: :station_skills, source: {:machine_skills, machine_name}},
      %BindingRef{name: :station_summary, source: {:machine_summary, machine_name}},
      %BindingRef{name: :station_events, source: {:machine_events, machine_name}},
      %BindingRef{
        name: :station_links,
        source:
          {:static_links,
           [
             %{
               label: "Operations",
               detail: "Return to the assigned runtime entry surface.",
               path: "/ops",
               disabled: false
             },
             %{
               label: "Machine Detail",
               detail: "Open the focused machine drill-down view.",
               path: "/ops/machines/#{machine_id}",
               disabled: false
             }
           ]}
      }
    ]
  end

  defp overview_surface_id(topology_id), do: "topology_#{topology_id}_overview"

  defp station_surface_id(topology_id, machine_id),
    do: "topology_#{topology_id}_#{machine_id}_station"

  defp overview_source_module(topology_id) do
    Module.concat([
      Ogol,
      HMI,
      Surfaces,
      StudioDrafts,
      Topologies,
      Macro.camelize(topology_id),
      "Overview"
    ])
  end

  defp station_source_module(topology_id, machine_id) do
    Module.concat([
      Ogol,
      HMI,
      Surfaces,
      StudioDrafts,
      Topologies,
      Macro.camelize(topology_id),
      Macro.camelize(machine_id),
      "Station"
    ])
  end

  defp topology_title(%Model{meaning: meaning}) when is_binary(meaning) and meaning != "",
    do: meaning

  defp topology_title(%Model{root: root}), do: humanize(root)

  defp machine_title(machine_id, machine, machine_titles) do
    case Map.get(machine_titles, machine_id) do
      title when is_binary(title) and title != "" ->
        title

      _ ->
        machine_title_from_runtime(machine_id, machine)
    end
  end

  defp machine_title_from_runtime(machine_id, machine) do
    case WorkspaceStore.fetch_machine(machine_id) do
      %{model: %{meaning: meaning}} when is_binary(meaning) and meaning != "" -> meaning
      _ -> machine_module_title(machine, machine_id)
    end
  end

  defp machine_draft_title(%{model: %{meaning: meaning}})
       when is_binary(meaning) and meaning != "",
       do: meaning

  defp machine_draft_title(%{id: id}), do: humanize(id)

  defp topology_from_bundle_model(%Model{} = topology), do: topology

  defp topology_from_bundle_model(%{
         topology_id: topology_id,
         strategy: strategy,
         meaning: meaning,
         machines: machines
       }) do
    %Model{
      root: String.to_atom(topology_id),
      strategy: String.to_atom(to_string(strategy)),
      meaning: meaning,
      machines: Enum.map(machines, &bundle_machine/1)
    }
  end

  defp topology_from_bundle_model(_other), do: nil

  defp bundle_machine(%{name: name, module_name: module_name, meaning: meaning}) do
    %{
      name: String.to_atom(to_string(name)),
      module: MachineSource.module_from_name!(module_name),
      meaning: meaning
    }
  end

  defp machine_module_title(machine, fallback_id) do
    case Map.get(machine, :module) do
      module when is_atom(module) ->
        case Info.machine_option(module, :meaning, nil) do
          meaning when is_binary(meaning) and meaning != "" -> meaning
          _ -> humanize(fallback_id)
        end

      _ ->
        humanize(fallback_id)
    end
  end

  defp machine_name(machine) do
    machine
    |> Map.get(:name)
  end

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
