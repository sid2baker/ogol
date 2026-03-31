defmodule Ogol.HMI.SurfaceDefaults do
  @moduledoc false

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.BindingRef
  alias Ogol.HMI.SurfacePrinter
  alias Ogol.HMI.Surfaces.{OperationsOverview, OperationsStation}
  alias Ogol.Machine.Info
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.WorkspaceStore.HmiSurfaceDraft
  alias Ogol.Topology.Model
  alias Ogol.Topology.Source, as: TopologySource

  def drafts_from_workspace do
    case select_workspace_topology(WorkspaceStore.list_topologies()) do
      nil ->
        []

      draft ->
        machine_titles =
          WorkspaceStore.list_machines()
          |> Map.new(fn machine_draft ->
            {machine_draft.id, machine_draft_title(machine_draft)}
          end)

        case topology_from_workspace_model(draft.model) do
          %Model{} = topology ->
            drafts_from_topology(topology, machine_titles: machine_titles)

          nil ->
            case TopologySource.from_source(draft.source) do
              {:ok, topology} -> drafts_from_topology(topology, machine_titles: machine_titles)
              {:error, _diagnostics} -> []
            end
        end
    end
  end

  def drafts_from_topology(%Model{} = topology, opts \\ []) do
    machine_titles = Keyword.get(opts, :machine_titles, %{})

    [
      overview_draft(topology)
      | Enum.map(topology.machines, &station_draft(topology, &1, machine_titles))
    ]
  end

  defp select_workspace_topology(drafts) do
    Enum.find(drafts, &(&1.id == WorkspaceStore.topology_default_id())) ||
      List.first(Enum.sort_by(drafts, & &1.id))
  end

  defp overview_draft(%Model{} = topology) do
    topology_id = to_string(topology.root)
    base = Surface.definition(OperationsOverview)

    definition = %{
      base
      | id: overview_surface_id(topology_id),
        title: "#{topology_title(topology)} Overview",
        summary: "Topology-wide operations surface for #{topology_title(topology)}.",
        bindings: [
          %BindingRef{name: :runtime_summary, source: {:topology_runtime_summary, topology.root}},
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

    draft_from_definition(
      to_string(definition.id),
      definition,
      overview_source_module(topology_id)
    )
  end

  defp station_draft(%Model{} = topology, machine, machine_titles) do
    machine_name = machine_name(machine)
    machine_id = to_string(machine_name)
    topology_id = to_string(topology.root)
    machine_title = machine_title(machine_id, machine, machine_titles)
    base = Surface.definition(OperationsStation)

    definition = %{
      base
      | id: station_surface_id(topology_id, machine_id),
        title: "#{machine_title} Station",
        summary:
          "Focused operator surface for #{machine_title} inside #{topology_title(topology)}.",
        bindings: [
          %BindingRef{name: :station_status, source: {:machine_status, machine_name}},
          %BindingRef{
            name: :station_alarm_summary,
            source: {:machine_alarm_summary, machine_name}
          },
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
    }

    draft_from_definition(
      to_string(definition.id),
      definition,
      station_source_module(topology_id, machine_id)
    )
  end

  defp draft_from_definition(id, %Surface{} = definition, source_module) do
    %HmiSurfaceDraft{
      id: id,
      source: SurfacePrinter.print(definition, module: source_module),
      source_module: source_module,
      model: definition,
      sync_state: :synced,
      sync_diagnostics: []
    }
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

  defp topology_from_workspace_model(%Model{} = topology), do: topology

  defp topology_from_workspace_model(%{
         topology_id: topology_id,
         strategy: strategy,
         meaning: meaning,
         machines: machines
       }) do
    %Model{
      root: String.to_atom(topology_id),
      strategy: String.to_atom(to_string(strategy)),
      meaning: meaning,
      machines: Enum.map(machines, &workspace_machine/1)
    }
  end

  defp topology_from_workspace_model(_other), do: nil

  defp workspace_machine(%{name: name, module_name: module_name, meaning: meaning}) do
    %{
      name: String.to_atom(to_string(name)),
      module: MachineSource.module_from_name!(module_name),
      meaning: meaning
    }
  end

  defp machine_title(machine_id, machine, machine_titles) do
    case Map.get(machine, :meaning) do
      meaning when is_binary(meaning) and meaning != "" ->
        meaning

      _ ->
        case Map.get(machine_titles, machine_id) do
          title when is_binary(title) and title != "" ->
            title

          _ ->
            machine_module_title(machine, machine_id)
        end
    end
  end

  defp machine_draft_title(%{model: %{meaning: meaning}})
       when is_binary(meaning) and meaning != "",
       do: meaning

  defp machine_draft_title(%{id: id}), do: humanize(id)

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

  defp machine_name(machine), do: Map.get(machine, :name)

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
