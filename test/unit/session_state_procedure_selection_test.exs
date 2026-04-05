defmodule Ogol.Session.StateProcedureSelectionTest do
  use ExUnit.Case, async: true

  alias Ogol.Session.ArtifactRuntime
  alias Ogol.Session.RuntimeState
  alias Ogol.Session.SequenceRunState
  alias Ogol.Session.State
  alias Ogol.Session.Workspace
  alias Ogol.Session.Workspace.SourceDraft

  defmodule StartupSequence do
    def __ogol_sequence__ do
      %Ogol.Sequence.Model{
        module: __MODULE__,
        sequence: %Ogol.Sequence.Model.SequenceDefinition{
          id: "startup",
          name: :startup,
          topology: __MODULE__.Topology
        }
      }
    end

    defmodule Topology do
    end
  end

  test "select_procedure stores the selected procedure while the session is idle" do
    state = state_with_sequences(["startup"])

    assert {:ok, next_state, :ok, [{:select_procedure, "startup"}], []} =
             State.apply_operation(state, {:select_procedure, "startup"})

    assert State.selected_procedure_id(next_state) == "startup"
  end

  test "select_procedure rejects unknown procedure ids" do
    assert :error =
             State.apply_operation(
               state_with_sequences(["startup"]),
               {:select_procedure, "missing"}
             )
  end

  test "select_procedure is rejected once a terminal run result is waiting to be cleared" do
    state =
      state_with_sequences(["startup"])
      |> Map.put(:sequence_run, %SequenceRunState{status: :completed, sequence_id: "startup"})

    assert :error = State.apply_operation(state, {:select_procedure, "startup"})
  end

  test "deleting the selected procedure clears the session selection" do
    state =
      state_with_sequences(["startup", "shutdown"])
      |> Map.put(:selected_procedure_id, "startup")

    assert {:ok, next_state, :ok, [{:delete_entry, :sequence, "startup"}],
            [{:delete_artifact, :sequence, "startup"}]} =
             State.apply_operation(state, {:delete_entry, :sequence, "startup"})

    assert State.selected_procedure_id(next_state) == nil
  end

  test "request_manual_takeover emits the controller action while a run owns orchestration" do
    state =
      state_with_sequences(["startup"])
      |> Map.put(:control_mode, :auto)
      |> Map.put(:owner, {:sequence_run, "run-1"})
      |> Map.put(:sequence_run, %SequenceRunState{
        status: :running,
        sequence_id: "startup",
        run_id: "run-1"
      })

    assert {:ok, next_state, :ok, [:request_manual_takeover], [:request_manual_takeover]} =
             State.apply_operation(state, :request_manual_takeover)

    assert next_state.pending_intent.takeover.requested? == false
  end

  test "start_sequence_run is rejected while a terminal result is waiting to be cleared" do
    state =
      startable_state("startup")
      |> Map.put(:sequence_run, %SequenceRunState{
        status: :completed,
        sequence_id: "startup",
        run_id: "run-1"
      })

    assert :error = State.apply_operation(state, {:start_sequence_run, "startup"})
  end

  test "clear_sequence_run_result rejects held runs so release stays controller-owned" do
    state =
      startable_state("startup")
      |> Map.put(:owner, {:sequence_run, "run-1"})
      |> Map.put(:sequence_run, %SequenceRunState{
        status: :held,
        sequence_id: "startup",
        run_id: "run-1",
        resumable?: true,
        resume_from_boundary: "step_1"
      })

    assert :error = State.apply_operation(state, :clear_sequence_run_result)
  end

  test "resume_sequence_run is rejected while manual takeover is pending" do
    state =
      startable_state("startup")
      |> Map.put(:control_mode, :auto)
      |> Map.put(:owner, {:sequence_run, "run-1"})
      |> Map.put(:pending_intent, %{
        pause: blank_intent(),
        abort: blank_intent(),
        takeover: %{blank_intent() | requested?: true}
      })
      |> Map.put(:sequence_run, %SequenceRunState{
        status: :paused,
        sequence_id: "startup",
        run_id: "run-1",
        resumable?: true,
        resume_from_boundary: "step_1",
        resume_blockers: []
      })

    assert :error = State.apply_operation(state, :resume_sequence_run)
  end

  defp state_with_sequences(ids) do
    sequence_entries =
      Map.new(ids, fn id ->
        {id,
         %SourceDraft{
           id: id,
           source: "sequence #{id}",
           model: %{name: String.to_atom(id), meaning: "#{id} meaning"},
           sync_state: :synced,
           sync_diagnostics: []
         }}
      end)

    %State{
      State.new()
      | workspace: %Workspace{
          entries: %{
            machine: %{},
            topology: %{},
            sequence: sequence_entries,
            hardware: %{},
            simulator_config: %{},
            hmi_surface: %{}
          }
        }
    }
  end

  defp startable_state(sequence_id) do
    state_with_sequences([sequence_id])
    |> Map.put(:control_mode, :auto)
    |> Map.put(:runtime, %RuntimeState{
      desired: {:running, :live},
      observed: {:running, :live},
      trust_state: :trusted,
      active_topology_module: StartupSequence.Topology,
      realized_workspace_hash: State.workspace_hash(state_with_sequences([sequence_id]).workspace)
    })
    |> Map.put(:artifact_runtime, %{
      {:sequence, sequence_id} => %ArtifactRuntime{
        id: {:sequence, sequence_id},
        kind: :sequence,
        artifact_id: sequence_id,
        module: StartupSequence,
        source_digest: nil,
        blocked_reason: nil,
        lingering_pids: [],
        diagnostics: []
      }
    })
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
