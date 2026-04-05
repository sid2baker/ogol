defmodule Ogol.Session.OperatorProcedureCatalogTest do
  use ExUnit.Case, async: true

  alias Ogol.Session.ArtifactRuntime
  alias Ogol.Session.OperatorProcedureCatalog
  alias Ogol.Session.RuntimeState
  alias Ogol.Session.SequenceRunState
  alias Ogol.Session.State
  alias Ogol.Session.Workspace
  alias Ogol.Session.Workspace.SourceDraft

  defmodule ActiveTopology do
  end

  defmodule OtherTopology do
  end

  defmodule MatchingSequence do
    def __ogol_sequence__ do
      %Ogol.Sequence.Model{
        module: __MODULE__,
        sequence: %Ogol.Sequence.Model.SequenceDefinition{
          id: "matching",
          name: :matching_sequence,
          topology: ActiveTopology,
          meaning: "Match the active cell"
        }
      }
    end
  end

  defmodule MismatchedSequence do
    def __ogol_sequence__ do
      %Ogol.Sequence.Model{
        module: __MODULE__,
        sequence: %Ogol.Sequence.Model.SequenceDefinition{
          id: "mismatched",
          name: :mismatched_sequence,
          topology: OtherTopology,
          meaning: "Belongs to another cell"
        }
      }
    end
  end

  test "catalog distinguishes topology eligibility from current startability" do
    state =
      base_state()
      |> Map.put(:control_mode, :manual)
      |> Map.put(:selected_procedure_id, "matching")

    assert Enum.map(OperatorProcedureCatalog.build(state), & &1.sequence_id) == [
             "blocked",
             "matching",
             "mismatched"
           ]
  end

  test "catalog returns stable eligibility and blocked reason codes" do
    state =
      base_state()
      |> Map.put(:control_mode, :manual)
      |> Map.put(:selected_procedure_id, "matching")

    entries = Map.new(OperatorProcedureCatalog.build(state), &{&1.sequence_id, &1})

    assert %{
             eligible?: true,
             startable?: false,
             blocked_reason_code: :auto_mode_required,
             blocked_reason_text: "Switch the cell to Auto before starting a procedure.",
             selected?: true
           } = entries["matching"]

    assert %{
             eligible?: false,
             eligibility_reason_code: :topology_mismatch,
             eligibility_reason_text: "Procedure does not belong to the active cell topology.",
             startable?: false,
             blocked_reason_code: nil
           } = entries["mismatched"]

    assert %{
             eligible?: false,
             eligibility_reason_code: :runtime_artifact_blocked,
             eligibility_reason_text: "Procedure is blocked in the active runtime.",
             startable?: false
           } = entries["blocked"]
  end

  test "catalog surfaces active and takeover-pending procedure state from session truth" do
    state =
      base_state()
      |> Map.put(:control_mode, :auto)
      |> Map.put(:owner, {:sequence_run, "run-1"})
      |> Map.put(:pending_intent, %{
        pause: blank_intent(),
        abort: blank_intent(),
        takeover: %{blank_intent() | requested?: true, admitted?: true}
      })
      |> Map.put(:sequence_run, %SequenceRunState{
        status: :running,
        sequence_id: "matching",
        run_id: "run-1"
      })

    entries = Map.new(OperatorProcedureCatalog.build(state), &{&1.sequence_id, &1})

    assert %{
             eligible?: true,
             active?: true,
             startable?: false,
             blocked_reason_code: :manual_takeover_pending,
             blocked_reason_text: "Manual takeover is pending."
           } = entries["matching"]

    assert %{
             eligible?: false,
             eligibility_reason_code: :topology_mismatch
           } = entries["mismatched"]
  end

  test "catalog marks procedures ineligible while runtime is stopped" do
    state =
      base_state()
      |> Map.put(:runtime, %RuntimeState{observed: :stopped, active_topology_module: nil})

    entries = Map.new(OperatorProcedureCatalog.build(state), &{&1.sequence_id, &1})

    assert entries["matching"].eligible? == false
    assert entries["matching"].eligibility_reason_code == :runtime_not_running
    assert entries["matching"].eligibility_reason_text == "Runtime is not running."
  end

  defp base_state do
    %State{
      State.new()
      | workspace: %Workspace{
          entries: %{
            machine: %{},
            topology: %{},
            sequence: %{
              "blocked" => draft("blocked", :blocked_sequence, "Blocked procedure"),
              "matching" => draft("matching", :matching_sequence, "Matching procedure"),
              "mismatched" => draft("mismatched", :mismatched_sequence, "Mismatched procedure")
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
          {:sequence, "blocked"} => %ArtifactRuntime{
            id: {:sequence, "blocked"},
            kind: :sequence,
            artifact_id: "blocked",
            module: nil,
            blocked_reason: :old_code_in_use
          },
          {:sequence, "matching"} => %ArtifactRuntime{
            id: {:sequence, "matching"},
            kind: :sequence,
            artifact_id: "matching",
            module: MatchingSequence
          },
          {:sequence, "mismatched"} => %ArtifactRuntime{
            id: {:sequence, "mismatched"},
            kind: :sequence,
            artifact_id: "mismatched",
            module: MismatchedSequence
          }
        }
    }
  end

  defp draft(id, name, meaning) do
    %SourceDraft{
      id: id,
      source: "sequence #{id}",
      model: %{name: name, meaning: meaning},
      sync_state: :synced,
      sync_diagnostics: []
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
