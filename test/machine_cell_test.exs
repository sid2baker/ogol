defmodule Ogol.Studio.MachineCellTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.Cell
  alias Ogol.Studio.MachineCell

  test "unsupported machine source falls back to source view" do
    facts =
      MachineCell.facts_from_assigns(%{
        machine_id: "packaging_line",
        draft_source: "defmodule Example do end",
        machine_model: nil,
        machine_draft: %Ogol.Studio.MachineDraftStore.Draft{},
        current_source_digest: "abc",
        runtime_status: MachineCell.default_runtime_status(),
        sync_state: :unsupported,
        sync_diagnostics: ["memory fields require source editing"],
        machine_issue: nil,
        validation_errors: [],
        requested_view: :visual
      })

    derived = Cell.derive(MachineCell, facts)

    assert derived.selected_view == :source
    assert Enum.any?(derived.views, &(&1.id == :visual and not &1.available?))
    assert derived.notice.title == "Visual editor unavailable"
    assert Enum.map(derived.actions, & &1.id) == [:build]
  end

  test "visual validation keeps visual selected and shows a warning notice" do
    facts =
      MachineCell.facts_from_assigns(%{
        machine_id: "packaging_line",
        draft_source: "defmodule Example do end",
        machine_model: %{},
        machine_draft: %Ogol.Studio.MachineDraftStore.Draft{},
        current_source_digest: "abc",
        runtime_status: MachineCell.default_runtime_status(),
        sync_state: :synced,
        sync_diagnostics: [],
        machine_issue: nil,
        validation_errors: ["Transitions must reference an existing state."],
        requested_view: :visual
      })

    derived = Cell.derive(MachineCell, facts)

    assert derived.selected_view == :visual
    assert derived.notice.title == "Visual update blocked"
    assert derived.notice.message == "Transitions must reference an existing state."
    assert [%{id: :build, enabled?: false}] = derived.actions
  end

  test "built machine enables apply" do
    facts =
      MachineCell.facts_from_assigns(%{
        machine_id: "packaging_line",
        draft_source: "defmodule Example do end",
        machine_model: %{},
        machine_draft: %Ogol.Studio.MachineDraftStore.Draft{},
        current_source_digest: "abc",
        runtime_status: %{MachineCell.default_runtime_status() | built_source_digest: "abc"},
        sync_state: :synced,
        sync_diagnostics: [],
        machine_issue: nil,
        validation_errors: [],
        requested_view: :visual
      })

    derived = Cell.derive(MachineCell, facts)

    assert Enum.map(derived.actions, & &1.id) == [:build, :apply]
    assert Enum.any?(derived.actions, &(&1.id == :apply and &1.enabled?))
  end
end
