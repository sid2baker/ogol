defmodule Ogol.StudioWorkspaceStoreTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.WorkspaceStore.MachineDraft
  alias Ogol.Studio.WorkspaceStore.RuntimeEntry
  alias Ogol.Studio.WorkspaceStore.SequenceDraft
  alias Ogol.Studio.WorkspaceStore.State

  test "reduce/2 updates source-backed entries and clears machine compile diagnostics on source change" do
    state = %State{
      entries: %{
        machine: %{
          "packaging_line" => %MachineDraft{
            id: "packaging_line",
            source: "old source",
            model: %{meaning: "old"},
            sync_state: :synced,
            sync_diagnostics: [],
            build_diagnostics: ["stale compile failure"]
          }
        }
      }
    }

    {draft, next_state} =
      WorkspaceStore.reduce(
        state,
        {:save_source, :machine, "packaging_line", "new source", %{meaning: "new"}, :synced, []}
      )

    assert draft.source == "new source"
    assert draft.model == %{meaning: "new"}
    assert draft.build_diagnostics == []

    assert next_state.entries.machine["packaging_line"].source == "new source"
    assert next_state.entries.machine["packaging_line"].build_diagnostics == []
  end

  test "reduce/2 normalizes compile diagnostics for sequence entries" do
    state = %State{
      entries: %{
        sequence: %{
          "packaging_auto" => %SequenceDraft{
            id: "packaging_auto",
            source: "sequence source",
            model: %{id: "packaging_auto"},
            sync_state: :synced,
            sync_diagnostics: [],
            compile_diagnostics: []
          }
        }
      }
    }

    {draft, next_state} =
      WorkspaceStore.reduce(
        state,
        {:record_compile, :sequence, "packaging_auto", [%{message: "compile failed"}]}
      )

    assert draft.compile_diagnostics == ["compile failed"]
    assert next_state.entries.sequence["packaging_auto"].compile_diagnostics == ["compile failed"]
  end

  test "reduce/2 tracks loaded runtime modules inside workspace state" do
    state = %State{}

    {entry, next_state} =
      WorkspaceStore.reduce(
        state,
        {:runtime_mark_loaded, {:machine, "packaging_line"},
         Ogol.Generated.Machines.PackagingLine, "abc123"}
      )

    assert %RuntimeEntry{} = entry
    assert entry.id == {:machine, "packaging_line"}
    assert entry.module == Ogol.Generated.Machines.PackagingLine
    assert entry.source_digest == "abc123"
    assert entry.blocked_reason == nil

    assert next_state.runtime_entries[{:machine, "packaging_line"}].module ==
             Ogol.Generated.Machines.PackagingLine
  end

  test "apply_operation/2 plans compile-and-load actions for code-backed entries" do
    state = %State{
      entries: %{
        machine: %{
          "packaging_line" => %MachineDraft{
            id: "packaging_line",
            source: "defmodule Ogol.Generated.Machines.PackagingLine do end",
            model: %{module_name: "Ogol.Generated.Machines.PackagingLine"},
            sync_state: :synced,
            sync_diagnostics: [],
            build_diagnostics: []
          }
        }
      }
    }

    assert {:ok, ^state, actions, nil} =
             WorkspaceStore.apply_operation(state, {:compile_entry, :machine, "packaging_line"})

    assert actions == [
             {:compile_and_load, :machine, "packaging_line",
              "defmodule Ogol.Generated.Machines.PackagingLine do end",
              %{module_name: "Ogol.Generated.Machines.PackagingLine"}}
           ]
  end
end
