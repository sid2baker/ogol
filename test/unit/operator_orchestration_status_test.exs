defmodule Ogol.Session.OperatorOrchestrationStatusTest do
  use ExUnit.Case, async: true

  alias Ogol.Session.ArtifactRuntime
  alias Ogol.Session.OperatorOrchestrationStatus
  alias Ogol.Session.RuntimeState
  alias Ogol.Session.SequenceRunState
  alias Ogol.Session.State
  alias Ogol.Session.Workspace
  alias Ogol.Session.Workspace.SourceDraft

  defmodule ActiveTopology do
  end

  defmodule StartupSequence do
    def __ogol_sequence__ do
      %Ogol.Sequence.Model{
        module: __MODULE__,
        sequence: %Ogol.Sequence.Model.SequenceDefinition{
          id: "startup",
          name: :startup,
          topology: ActiveTopology,
          meaning: "Start the active cell"
        }
      }
    end
  end

  test "reports idle auto control with a selected procedure as startable" do
    state =
      base_state()
      |> Map.put(:control_mode, :auto)
      |> Map.put(:selected_procedure_id, "startup")

    status = OperatorOrchestrationStatus.build(state)

    assert status.control_mode == :auto
    assert status.owner_kind == :manual_operator
    assert status.selected_procedure_id == "startup"
    assert status.actions.run_selected? == true
    assert status.actions.arm_auto? == false
    assert status.actions.switch_to_manual? == true
  end

  test "reports takeover-pending active runs and disables duplicate takeover requests" do
    state =
      base_state()
      |> Map.put(:control_mode, :auto)
      |> Map.put(:owner, {:sequence_run, "run-1"})
      |> Map.put(:pending_intent, %{
        pause: blank_intent(),
        abort: %{blank_intent() | requested?: true},
        takeover: %{blank_intent() | requested?: true}
      })
      |> Map.put(:sequence_run, %SequenceRunState{
        status: :running,
        sequence_id: "startup",
        run_id: "run-1",
        current_step_label: "Hold fill line"
      })

    status = OperatorOrchestrationStatus.build(state, topology_scope: "active_topology")

    assert status.owner_kind == :manual_takeover_pending
    assert status.active_run.status == :running
    assert status.pending_intent.takeover_requested? == true
    assert status.actions.request_manual_takeover? == false
    assert status.actions.abort? == true
    assert status.scope_matches_runtime? == true
  end

  test "disables run and resume actions when the selected procedure is blocked or takeover is pending" do
    state =
      base_state()
      |> Map.put(:control_mode, :auto)
      |> Map.put(:selected_procedure_id, "startup")
      |> Map.put(:pending_intent, %{
        pause: blank_intent(),
        abort: blank_intent(),
        takeover: %{blank_intent() | requested?: true}
      })
      |> Map.put(:runtime, %RuntimeState{
        observed: {:running, :live},
        trust_state: :invalidated,
        invalidation_reasons: [:workspace_changed],
        active_topology_module: ActiveTopology
      })
      |> Map.put(:owner, {:sequence_run, "run-1"})
      |> Map.put(:sequence_run, %SequenceRunState{
        status: :paused,
        sequence_id: "startup",
        run_id: "run-1",
        resumable?: true,
        resume_from_boundary: "fill_line",
        resume_blockers: []
      })

    status = OperatorOrchestrationStatus.build(state)

    assert status.actions.run_selected? == false
    assert status.actions.resume? == false
  end

  defp base_state do
    %State{
      State.new()
      | workspace: %Workspace{
          entries: %{
            machine: %{},
            topology: %{},
            sequence: %{
              "startup" => %SourceDraft{
                id: "startup",
                source: "sequence startup",
                model: %{name: :startup, meaning: "Start the active cell"},
                sync_state: :synced,
                sync_diagnostics: []
              }
            },
            hardware: %{},
            simulator_config: %{},
            hmi_surface: %{}
          }
        },
        runtime: %RuntimeState{
          observed: {:running, :live},
          trust_state: :trusted,
          active_topology_module: ActiveTopology
        },
        artifact_runtime: %{
          {:sequence, "startup"} => %ArtifactRuntime{
            id: {:sequence, "startup"},
            kind: :sequence,
            artifact_id: "startup",
            module: StartupSequence
          }
        }
    }
  end

  defp blank_intent do
    %{
      requested?: false,
      requested_by: nil,
      requested_at: nil,
      admitted?: false,
      admitted_at: nil,
      fulfilled?: false,
      fulfilled_at: nil
    }
  end
end
