defmodule Ogol.Session.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Ogol.Session.Data
  alias Ogol.Session.Workspace
  alias Ogol.Session.Workspace.SourceDraft

  test "new/0 starts with an empty workspace" do
    assert %Data{} = state = Data.new()
    workspace = Data.workspace(state)

    assert workspace.entries == %{
             driver: %{},
             machine: %{},
             topology: %{},
             sequence: %{},
             hardware_config: %{},
             hmi_surface: %{}
           }

    assert workspace.loaded_revision == nil
  end

  test "reduce/2 updates source-backed entries without runtime compile state" do
    state = %Workspace{
      entries: %{
        machine: %{
          "packaging_line" => %SourceDraft{
            id: "packaging_line",
            source: "old source",
            model: %{meaning: "old"},
            sync_state: :synced,
            sync_diagnostics: []
          }
        }
      }
    }

    operation =
      {:save_source, :machine, "packaging_line", "new source", %{meaning: "new"}, :synced, []}

    {draft, next_state, operations} = Workspace.reduce(state, operation)

    assert draft.source == "new source"
    assert draft.model == %{meaning: "new"}
    assert next_state.entries.machine["packaging_line"].source == "new source"
    assert operations == [operation]
  end

  test "reduce/2 persists sequence source-only sync diagnostics" do
    state = %Workspace{
      entries: %{
        sequence: %{
          "packaging_auto" => %SourceDraft{
            id: "packaging_auto",
            source: "sequence source",
            model: %{id: "packaging_auto"},
            sync_state: :synced,
            sync_diagnostics: []
          }
        }
      }
    }

    operation =
      {:save_source, :sequence, "packaging_auto", "updated source", nil, :unsupported,
       ["compile failed"]}

    {draft, next_state, operations} = Workspace.reduce(state, operation)

    assert draft.source == "updated source"
    assert draft.sync_state == :unsupported
    assert draft.sync_diagnostics == ["compile failed"]
    assert next_state.entries.sequence["packaging_auto"].sync_diagnostics == ["compile failed"]
    assert operations == [operation]
  end

  test "reduce/2 creates entries for empty kinds in a fresh workspace state" do
    state = %Workspace{entries: %{}}

    operation = {:create_entry, :machine, "machine_1"}
    {draft, next_state, operations} = Workspace.reduce(state, operation)

    assert %SourceDraft{} = draft
    assert draft.id == "machine_1"
    assert next_state.entries.machine["machine_1"].id == "machine_1"
    assert operations == [operation]
  end

  test "reduce/2 returns normalized create operations for auto ids" do
    state = %Workspace{entries: %{machine: %{}}}

    assert {draft, next_state, [operation]} =
             Workspace.reduce(state, {:create_entry, :machine, :auto})

    assert draft.id == "machine_1"
    assert next_state.entries.machine["machine_1"].id == "machine_1"
    assert operation == {:create_entry, :machine, "machine_1"}
  end

  test "reduce/2 stores loaded revision metadata in source-only workspace state" do
    state = Workspace.new()

    operation =
      {:put_loaded_revision, "ogol", "r1",
       [%{kind: :machine, id: "packaging_line", module: Ogol.Generated.Machines.PackagingLine}]}

    {loaded_revision, next_state, operations} = Workspace.reduce(state, operation)

    assert loaded_revision.app_id == "ogol"
    assert loaded_revision.revision == "r1"

    assert next_state.loaded_revision.inventory == [
             %{
               kind: :machine,
               id: "packaging_line",
               module: Ogol.Generated.Machines.PackagingLine
             }
           ]

    assert operations == [operation]
  end

  test "apply_operation/2 wraps workspace updates and returns accepted operations" do
    state = %Data{
      workspace: %Workspace{
        entries: %{
          machine: %{
            "packaging_line" => %SourceDraft{
              id: "packaging_line",
              source: "defmodule Ogol.Generated.Machines.PackagingLine do end",
              model: %{module_name: "Ogol.Generated.Machines.PackagingLine"},
              sync_state: :synced,
              sync_diagnostics: []
            }
          }
        }
      }
    }

    operation =
      {:save_source, :machine, "packaging_line", "updated", %{module_name: "Foo"}, :synced, []}

    assert {:ok, next_state, draft, accepted_operations, actions} =
             Data.apply_operation(
               state,
               operation
             )

    assert draft.source == "updated"
    assert next_state.workspace.entries.machine["packaging_line"].source == "updated"
    assert accepted_operations == [operation]
    assert actions == []
  end

  test "apply_operation/2 derives delete_artifact actions for removed source-backed entries" do
    state = %Data{
      workspace: %Workspace{
        entries: %{
          machine: %{
            "packaging_line" => %SourceDraft{
              id: "packaging_line",
              source: "defmodule Ogol.Generated.Machines.PackagingLine do end",
              model: %{module_name: "Ogol.Generated.Machines.PackagingLine"},
              sync_state: :synced,
              sync_diagnostics: []
            }
          }
        }
      }
    }

    assert {:ok, next_state, :ok, [operation], actions} =
             Data.apply_operation(state, {:delete_entry, :machine, "packaging_line"})

    assert operation == {:delete_entry, :machine, "packaging_line"}
    assert next_state.workspace.entries.machine == %{}
    assert actions == [{:delete_artifact, :machine, "packaging_line"}]
  end

  test "apply_operation/2 derives topology deploy actions from the current workspace snapshot" do
    state = %Data{
      workspace: %Workspace{
        entries: %{
          topology: %{
            "packaging_line" => %SourceDraft{id: "packaging_line", source: "topology"}
          }
        }
      }
    }

    assert {:ok, next_state, :ok, [], [{:deploy_topology, "packaging_line", workspace}]} =
             Data.apply_operation(state, {:deploy_topology, "packaging_line"})

    assert next_state == state
    assert %Workspace{} = workspace
    assert Workspace.fetch(workspace, :topology, "packaging_line")
  end

  test "apply_operation/2 rejects runtime actions for missing workspace entries" do
    assert :error = Data.apply_operation(Data.new(), {:deploy_topology, "missing"})
  end

  test "apply_operation/2 derives restart actions from the current workspace snapshot" do
    assert {:ok, _next_state, :ok, [], [{:restart_active, workspace}]} =
             Data.apply_operation(Data.new(), :restart_active)

    assert %Workspace{} = workspace
  end
end
