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
        machine_draft: %Ogol.Studio.WorkspaceStore.MachineDraft{},
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
    assert Enum.map(derived.actions, & &1.id) == [:compile]
  end

  test "visual validation keeps visual selected and shows a warning notice" do
    facts =
      MachineCell.facts_from_assigns(%{
        machine_id: "packaging_line",
        draft_source: "defmodule Example do end",
        machine_model: %{},
        machine_draft: %Ogol.Studio.WorkspaceStore.MachineDraft{},
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
    assert [%{id: :compile, enabled?: false}] = derived.actions
  end

  test "compiled machine disables recompiling until the source changes" do
    facts =
      MachineCell.facts_from_assigns(%{
        machine_id: "packaging_line",
        draft_source: "defmodule Example do end",
        machine_model: %{},
        machine_draft: %Ogol.Studio.WorkspaceStore.MachineDraft{},
        current_source_digest: "abc",
        runtime_status: %{MachineCell.default_runtime_status() | source_digest: "abc"},
        sync_state: :synced,
        sync_diagnostics: [],
        machine_issue: nil,
        validation_errors: [],
        requested_view: :visual
      })

    derived = Cell.derive(MachineCell, facts)

    assert [%{id: :compile, enabled?: false}] = derived.actions
  end

  test "stale machine source shows a stale notice and allows recompiling" do
    facts =
      MachineCell.facts_from_assigns(%{
        machine_id: "packaging_line",
        draft_source: "defmodule Example do end",
        machine_model: %{},
        machine_draft: %Ogol.Studio.WorkspaceStore.MachineDraft{},
        current_source_digest: "def",
        runtime_status: %{MachineCell.default_runtime_status() | source_digest: "abc"},
        sync_state: :synced,
        sync_diagnostics: [],
        machine_issue: nil,
        validation_errors: [],
        requested_view: :visual
      })

    derived = Cell.derive(MachineCell, facts)

    assert derived.notice.title == "Compiled output is stale"
    assert [%{id: :compile, enabled?: true}] = derived.actions
  end
end
