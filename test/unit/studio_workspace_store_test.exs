defmodule Ogol.Session.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Ogol.Session.RuntimeState
  alias Ogol.Session.State
  alias Ogol.Session.Workspace
  alias Ogol.Session.Workspace.SourceDraft

  test "new/0 starts with an empty workspace" do
    assert %State{} = state = State.new()
    workspace = State.workspace(state)
    runtime = State.runtime(state)

    assert workspace.entries == %{
             machine: %{},
             topology: %{},
             sequence: %{},
             hardware: %{},
             simulator_config: %{},
             hmi_surface: %{}
           }

    assert workspace.loaded_revision == nil
    assert runtime.desired == :stopped
    assert runtime.observed == :stopped
    assert runtime.status == :idle
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
    state = %State{
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
             State.apply_operation(
               state,
               operation
             )

    assert draft.source == "updated"
    assert next_state.workspace.entries.machine["packaging_line"].source == "updated"
    assert accepted_operations == [operation]
    assert actions == []
  end

  test "apply_operation/2 derives delete_artifact actions for removed source-backed entries" do
    state = %State{
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
             State.apply_operation(state, {:delete_entry, :machine, "packaging_line"})

    assert operation == {:delete_entry, :machine, "packaging_line"}
    assert next_state.workspace.entries.machine == %{}
    assert actions == [{:delete_artifact, :machine, "packaging_line"}]
  end

  test "apply_operation/2 derives runtime reconciliation from desired realization" do
    state = %State{
      workspace: %Workspace{
        entries: %{
          topology: %{
            "packaging_line" => %SourceDraft{id: "packaging_line", source: "topology"}
          }
        }
      }
    }

    assert {:ok, next_state, :ok, [{:set_desired_runtime, {:running, :live}}],
            [{:reconcile_runtime, workspace, runtime}]} =
             State.apply_operation(state, {:set_desired_runtime, {:running, :live}})

    assert next_state.runtime.desired == {:running, :live}
    assert next_state.runtime.status == :reconciling
    assert %Workspace{} = workspace
    assert %Ogol.Session.RuntimeState{desired: {:running, :live}} = runtime
  end

  test "apply_operation/2 can reset runtime state back to the session default" do
    state = %State{
      workspace: Workspace.new(),
      runtime: %RuntimeState{
        desired: {:running, :live},
        observed: {:running, :live},
        status: :running,
        deployment_id: "d4",
        active_topology_module: Ogol.Generated.Topologies.PackagingLine,
        active_adapters: [:ethercat],
        realized_workspace_hash: "abc"
      }
    }

    assert {:ok, next_state, :ok, [:reset_runtime_state], []} =
             State.apply_operation(state, :reset_runtime_state)

    assert next_state.runtime == %RuntimeState{}
  end

  test "apply_operation/2 records runtime start feedback in session truth" do
    state = State.new()

    assert {:ok, next_state, :ok, [{:runtime_started, {:running, :live}, details}], []} =
             State.apply_operation(
               state,
               {:runtime_started, {:running, :live},
                %{
                  deployment_id: "d9",
                  active_topology_module: Ogol.Generated.Topologies.PackagingLine,
                  active_adapters: [:ethercat],
                  realized_workspace_hash: "abc"
                }}
             )

    assert next_state.runtime.observed == {:running, :live}
    assert next_state.runtime.status == :running
    assert next_state.runtime.deployment_id == "d9"
    assert next_state.runtime.active_topology_module == Ogol.Generated.Topologies.PackagingLine
    assert next_state.runtime.active_adapters == [:ethercat]
    assert next_state.runtime.realized_workspace_hash == "abc"
    assert details.realized_workspace_hash == "abc"
  end

  test "apply_operation/2 records runtime stop feedback in session truth" do
    state = %State{
      runtime: %Ogol.Session.RuntimeState{
        desired: :stopped,
        observed: {:running, :live},
        status: :running,
        deployment_id: "d4",
        active_topology_module: Ogol.Generated.Topologies.PackagingLine,
        active_adapters: [:ethercat],
        realized_workspace_hash: "abc"
      },
      workspace: Workspace.new()
    }

    assert {:ok, next_state, :ok, [{:runtime_stopped, %{realized_workspace_hash: nil}}], []} =
             State.apply_operation(state, {:runtime_stopped, %{realized_workspace_hash: nil}})

    assert next_state.runtime.observed == :stopped
    assert next_state.runtime.status == :idle
    assert next_state.runtime.deployment_id == nil
    assert next_state.runtime.active_topology_module == nil
    assert next_state.runtime.active_adapters == []
    assert next_state.runtime.realized_workspace_hash == nil
  end

  test "apply_operation/2 records runtime failure as a stopped failed runtime" do
    state = %State{
      runtime: %Ogol.Session.RuntimeState{
        desired: {:running, :live},
        observed: {:running, :live},
        status: :running,
        deployment_id: "d4",
        active_topology_module: Ogol.Generated.Topologies.PackagingLine,
        active_adapters: [:ethercat],
        realized_workspace_hash: "abc"
      },
      workspace: Workspace.new()
    }

    assert {:ok, next_state, :ok, [{:runtime_failed, {:running, :live}, :boom}], []} =
             State.apply_operation(state, {:runtime_failed, {:running, :live}, :boom})

    assert next_state.runtime.desired == {:running, :live}
    assert next_state.runtime.observed == :stopped
    assert next_state.runtime.status == :failed
    assert next_state.runtime.deployment_id == nil
    assert next_state.runtime.active_topology_module == nil
    assert next_state.runtime.active_adapters == []
    assert next_state.runtime.realized_workspace_hash == nil
    assert next_state.runtime.last_error == :boom
  end
end
