defmodule Ogol.Topology.Studio.CellTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.Cell, as: StudioCellModel
  alias Ogol.Topology.Studio.Cell, as: TopologyCell

  test "unsupported topology source falls back to source view" do
    facts =
      TopologyCell.facts_from_assigns(%{
        topology_artifact_id: "packaging_line",
        draft_source: "defmodule Example do end",
        current_source_digest: "abc",
        topology_model: nil,
        topology_draft: %Ogol.Session.Workspace.SourceDraft{},
        runtime_status: %{
          selected_module: :example,
          active: nil,
          selected_running?: false,
          other_running?: false,
          source_digest: nil,
          blocked_reason: nil,
          lingering_pids: []
        },
        sync_state: :unsupported,
        sync_diagnostics: ["unsupported top-level constructs"],
        validation_errors: [],
        studio_feedback: nil,
        requested_view: :visual
      })

    derived = StudioCellModel.derive(TopologyCell, facts)

    assert derived.selected_view == :source
    assert Enum.any?(derived.views, &(&1.id == :visual and not &1.available?))
    assert derived.notice.title == "Visual editor unavailable"
  end

  test "running topology exposes stop controls" do
    facts =
      TopologyCell.facts_from_assigns(%{
        topology_artifact_id: "packaging_line",
        draft_source: "defmodule Example do end",
        current_source_digest: "abc",
        topology_model: %{module_name: "Ogol.Generated.Topologies.PackagingLine"},
        topology_draft: %Ogol.Session.Workspace.SourceDraft{},
        runtime_status: %{
          selected_module: Ogol.Generated.Topologies.PackagingLine,
          active: %{
            module: Ogol.Generated.Topologies.PackagingLine,
            topology_scope: :packaging_line,
            pid: self()
          },
          selected_running?: true,
          other_running?: false,
          source_digest: "abc",
          blocked_reason: nil,
          lingering_pids: []
        },
        sync_state: :synced,
        sync_diagnostics: [],
        validation_errors: [],
        studio_feedback: nil,
        requested_view: :visual
      })

    derived = StudioCellModel.derive(TopologyCell, facts)

    assert Enum.map(derived.controls, & &1.id) == [:recompile, :restart, :stop]

    assert [
             %{operation: {:compile_artifact, :topology, "packaging_line"}},
             %{operation: :restart_active},
             %{operation: {:stop_topology, "packaging_line"}}
           ] = derived.controls

    assert derived.notice.title == "Running"
  end
end
