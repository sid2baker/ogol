defmodule Ogol.HMI.Surface.Defaults do
  @moduledoc false

  alias Ogol.HMI.Surface
  alias Ogol.HMI.Surface.BindingRef
  alias Ogol.HMI.Surface.Builtins.{OperationsOverview, OperationsStation}
  alias Ogol.HMI.Surface.Printer
  alias Ogol.Machine.Info
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Session
  alias Ogol.Session.Workspace.SourceDraft
  alias Ogol.Topology
  alias Ogol.Topology.Model
  alias Ogol.Topology.Source, as: TopologySource

  def drafts_from_workspace(opts \\ []) do
    topology_id = Keyword.get(opts, :topology_id)

    case select_workspace_topology(Session.topology(), topology_id) do
      nil ->
        []

      draft ->
        machine_titles =
          Session.list_machines()
          |> Map.new(fn machine_draft ->
            {machine_draft.id, machine_draft_title(machine_draft)}
          end)

        case topology_from_workspace_model(draft.model) do
          %Model{} = topology ->
            drafts_from_topology(topology, machine_titles: machine_titles)

          nil ->
            case topology_projection_from_source(draft.source) do
              %Model{} = topology ->
                drafts_from_topology(topology, machine_titles: machine_titles)

              nil ->
                []
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

  defp select_workspace_topology(nil, _topology_id), do: nil

  defp select_workspace_topology(draft, nil) do
    draft
  end

  defp select_workspace_topology(draft, topology_id) when is_binary(topology_id) do
    if workspace_topology_scope(draft) == topology_id, do: draft, else: nil
  end

  defp overview_draft(%Model{} = topology) do
    topology_id = topology_scope_name(topology)
    topology_scope = topology_scope(topology)
    base = Surface.definition(OperationsOverview)

    definition = %{
      base
      | id: overview_surface_id(topology_id),
        title: "#{topology_title(topology)} Overview",
        summary: "Topology-wide operations surface for #{topology_title(topology)}.",
        bindings: [
          %BindingRef{
            name: :runtime_summary,
            source: {:topology_runtime_summary, topology_scope}
          },
          %BindingRef{
            name: :alarm_summary,
            source: {:topology_alarm_summary, topology_scope}
          },
          %BindingRef{
            name: :orchestration_status,
            source: {:topology_orchestration_status, topology_scope}
          },
          %BindingRef{
            name: :procedure_catalog,
            source: {:topology_procedure_catalog, topology_scope}
          },
          %BindingRef{
            name: :machine_registry,
            source: {:topology_machine_registry, topology_scope}
          },
          %BindingRef{
            name: :event_stream,
            source: {:topology_event_stream, topology_scope}
          },
          %BindingRef{name: :ops_links, source: {:topology_links, topology_scope}}
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
    topology_id = topology_scope_name(topology)
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
    %SourceDraft{
      id: id,
      source: Printer.print(definition, module: source_module),
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
      "Ogol",
      "HMI",
      "Surface",
      "StudioDrafts",
      "Topologies",
      Macro.camelize(topology_id),
      "Overview"
    ])
  end

  defp station_source_module(topology_id, machine_id) do
    Module.concat([
      "Ogol",
      "HMI",
      "Surface",
      "StudioDrafts",
      "Topologies",
      Macro.camelize(topology_id),
      Macro.camelize(machine_id),
      "Station"
    ])
  end

  defp topology_title(%Model{meaning: meaning}) when is_binary(meaning) and meaning != "",
    do: meaning

  defp topology_title(%Model{module: module}) when is_atom(module),
    do: humanize(Topology.scope_name(module))

  defp topology_from_workspace_model(%Model{} = topology), do: topology

  defp topology_from_workspace_model(%{
         module_name: module_name,
         strategy: strategy,
         meaning: meaning,
         machines: machines
       }) do
    %Model{
      module: TopologySource.module_from_name!(module_name),
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

  defp workspace_topology_scope(%{model: %Model{} = topology}), do: topology_scope_name(topology)

  defp workspace_topology_scope(%{model: model}) when is_map(model) do
    model
    |> topology_from_workspace_model()
    |> case do
      %Model{} = topology -> topology_scope_name(topology)
      _other -> nil
    end
  end

  defp workspace_topology_scope(%{source: source}) when is_binary(source) do
    case topology_projection_from_source(source) do
      %Model{} = topology -> topology_scope_name(topology)
      nil -> nil
    end
  end

  defp workspace_topology_scope(_draft), do: nil

  defp topology_projection_from_source(source) when is_binary(source) do
    case TopologySource.from_source(source) do
      {:ok, model} ->
        topology_from_workspace_model(model)

      {:error, _diagnostics} ->
        case TopologySource.contract_projection_from_source(source) do
          {:ok, model} -> topology_from_workspace_model(model)
          {:error, _diagnostics} -> nil
        end
    end
  end

  defp topology_scope_name(%Model{module: module}) when is_atom(module),
    do: Topology.scope_name(module)

  defp topology_scope(%Model{module: module}) when is_atom(module), do: Topology.scope(module)

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
