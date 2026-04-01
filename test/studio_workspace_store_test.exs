defmodule Ogol.StudioWorkspaceStoreTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.WorkspaceStore.MachineDraft
  alias Ogol.Studio.WorkspaceStore.SequenceDraft
  alias Ogol.Studio.WorkspaceStore.State

  test "init/1 seeds the default draft workspace entries" do
    assert {:ok, %State{} = state} = WorkspaceStore.init([])

    assert Map.has_key?(state.entries.driver, WorkspaceStore.driver_default_id())
    assert Map.has_key?(state.entries.machine, WorkspaceStore.machine_default_id())
    assert Map.has_key?(state.entries.topology, WorkspaceStore.topology_default_id())
    assert Map.has_key?(state.entries.hardware_config, WorkspaceStore.hardware_config_entry_id())
  end

  test "reduce/2 updates source-backed entries without runtime compile state" do
    state = %State{
      entries: %{
        machine: %{
          "packaging_line" => %MachineDraft{
            id: "packaging_line",
            source: "old source",
            model: %{meaning: "old"},
            sync_state: :synced,
            sync_diagnostics: []
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

    assert next_state.entries.machine["packaging_line"].source == "new source"
  end

  test "reduce/2 persists sequence source-only sync diagnostics" do
    state = %State{
      entries: %{
        sequence: %{
          "packaging_auto" => %SequenceDraft{
            id: "packaging_auto",
            source: "sequence source",
            model: %{id: "packaging_auto"},
            sync_state: :synced,
            sync_diagnostics: []
          }
        }
      }
    }

    {draft, next_state} =
      WorkspaceStore.reduce(
        state,
        {:save_source, :sequence, "packaging_auto", "updated source", nil, :unsupported,
         ["compile failed"]}
      )

    assert draft.source == "updated source"
    assert draft.sync_state == :unsupported
    assert draft.sync_diagnostics == ["compile failed"]
    assert next_state.entries.sequence["packaging_auto"].sync_diagnostics == ["compile failed"]
  end

  test "reduce/2 creates entries for empty kinds in a fresh workspace state" do
    state = %State{entries: %{}}

    {draft, next_state} = WorkspaceStore.reduce(state, {:create_entry, :machine, "machine_1"})

    assert %MachineDraft{} = draft
    assert draft.id == "machine_1"
    assert next_state.entries.machine["machine_1"].id == "machine_1"
  end

  test "reduce/2 stores loaded revision metadata in source-only workspace state" do
    state = %State{}

    {loaded_revision, next_state} =
      WorkspaceStore.reduce(
        state,
        {:put_loaded_revision, "ogol", "r1",
         [%{kind: :machine, id: "packaging_line", module: Ogol.Generated.Machines.PackagingLine}]}
      )

    assert loaded_revision.app_id == "ogol"
    assert loaded_revision.revision == "r1"

    assert next_state.loaded_revision.inventory == [
             %{
               kind: :machine,
               id: "packaging_line",
               module: Ogol.Generated.Machines.PackagingLine
             }
           ]
  end

  test "apply_operation/2 applies source operations without runtime actions" do
    state = %State{
      entries: %{
        machine: %{
          "packaging_line" => %MachineDraft{
            id: "packaging_line",
            source: "defmodule Ogol.Generated.Machines.PackagingLine do end",
            model: %{module_name: "Ogol.Generated.Machines.PackagingLine"},
            sync_state: :synced,
            sync_diagnostics: []
          }
        }
      }
    }

    assert {:ok, next_state, draft} =
             WorkspaceStore.apply_operation(
               state,
               {:save_source, :machine, "packaging_line", "updated", %{module_name: "Foo"},
                :synced, []}
             )

    assert draft.source == "updated"
    assert next_state.entries.machine["packaging_line"].source == "updated"
  end
end
