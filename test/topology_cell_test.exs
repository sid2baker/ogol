defmodule Ogol.Studio.TopologyCellTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.Cell
  alias Ogol.Studio.TopologyCell

  test "unsupported topology source falls back to source view" do
    facts =
      TopologyCell.facts_from_assigns(%{
        topology_id: "packaging_line",
        draft_source: "defmodule Example do end",
        topology_model: nil,
        runtime_status: %{selected_module: :example, active: nil, selected_running?: false, other_running?: false},
        sync_state: :unsupported,
        sync_diagnostics: ["unsupported top-level constructs"],
        validation_errors: [],
        studio_feedback: nil,
        requested_view: :visual
      })

    derived = Cell.derive(TopologyCell, facts)

    assert derived.selected_view == :source
    assert Enum.any?(derived.views, &(&1.id == :visual and not &1.available?))
    assert derived.notice.title == "Visual editor unavailable"
  end

  test "running topology exposes stop action" do
    facts =
      TopologyCell.facts_from_assigns(%{
        topology_id: "packaging_line",
        draft_source: "defmodule Example do end",
        topology_model: %{module_name: "Ogol.Generated.Topologies.PackagingLine"},
        runtime_status: %{
          selected_module: Ogol.Generated.Topologies.PackagingLine,
          active: %{module: Ogol.Generated.Topologies.PackagingLine, root: :packaging_line, pid: self()},
          selected_running?: true,
          other_running?: false
        },
        sync_state: :synced,
        sync_diagnostics: [],
        validation_errors: [],
        studio_feedback: nil,
        requested_view: :visual
      })

    derived = Cell.derive(TopologyCell, facts)

    assert Enum.map(derived.actions, & &1.id) == [:stop]
    assert derived.notice.title == "Running"
  end
end
