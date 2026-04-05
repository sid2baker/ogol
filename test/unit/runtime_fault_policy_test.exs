defmodule Ogol.Session.RuntimeFaultPolicyTest do
  use ExUnit.Case, async: true

  alias Ogol.Session.{RuntimeFaultPolicy, SequenceRunState}

  test "external_runtime_hold/2 preserves resumability for operator-ack holds" do
    snapshot = %{
      run_id: "sr1",
      resumable?: true,
      resume_from_boundary: "step_1",
      resume_stack: [:resume_marker],
      resume_blockers: []
    }

    held_snapshot = RuntimeFaultPolicy.external_runtime_hold(snapshot, [:workspace_changed])

    assert held_snapshot.run_id == "sr1"
    assert held_snapshot.resumable? == true
    assert held_snapshot.resume_from_boundary == "step_1"
    assert held_snapshot.resume_stack == [:resume_marker]
    assert held_snapshot.resume_blockers == []
    assert held_snapshot.fault_source == :external_runtime
    assert held_snapshot.fault_recoverability == :operator_ack_required
    assert held_snapshot.fault_scope == :runtime_wide
    assert held_snapshot.finished_at == nil
    assert held_snapshot.last_error == {:trust_invalidated, [:workspace_changed]}
  end

  test "external_runtime_hold/2 clears resumability when a fresh run is required" do
    snapshot = %{
      run_id: "sr2",
      resumable?: true,
      resume_from_boundary: "step_2",
      resume_stack: [:resume_marker],
      resume_blockers: []
    }

    held_snapshot =
      RuntimeFaultPolicy.external_runtime_hold(snapshot, [:topology_generation_changed])

    assert held_snapshot.run_id == "sr2"
    assert held_snapshot.resumable? == false
    assert held_snapshot.resume_from_boundary == nil
    assert held_snapshot.resume_stack == nil
    assert held_snapshot.resume_blockers == [:topology_generation_changed]
    assert held_snapshot.fault_source == :external_runtime
    assert held_snapshot.fault_recoverability == :abort_required
    assert held_snapshot.fault_scope == :runtime_wide
  end

  test "external_runtime_invalidation/2 appends runtime blockers onto held runs" do
    run = %SequenceRunState{
      status: :held,
      run_id: "sr3",
      resumable?: true,
      resume_from_boundary: "step_3",
      resume_blockers: []
    }

    updated_run =
      RuntimeFaultPolicy.external_runtime_invalidation(run, [:topology_generation_changed])

    assert updated_run.run_id == "sr3"
    assert updated_run.resumable? == false
    assert updated_run.resume_from_boundary == "step_3"
    assert updated_run.resume_blockers == [:topology_generation_changed]
    assert updated_run.fault_source == :external_runtime
    assert updated_run.fault_recoverability == :abort_required
    assert updated_run.fault_scope == :runtime_wide
    assert updated_run.last_error == {:trust_invalidated, [:topology_generation_changed]}
  end

  test "external_runtime_failure/2 preserves the active snapshot identity" do
    snapshot = %{
      run_id: "sr4",
      current_step_id: "step_4",
      resumable?: true,
      resume_blockers: []
    }

    failed_snapshot =
      RuntimeFaultPolicy.external_runtime_failure(snapshot, {:sequence_runner_exited, :boom})

    assert failed_snapshot.run_id == "sr4"
    assert failed_snapshot.current_step_id == "step_4"
    assert failed_snapshot.resumable? == false
    assert failed_snapshot.resume_blockers == [:terminal_state]
    assert failed_snapshot.fault_source == :external_runtime
    assert failed_snapshot.fault_recoverability == :abort_required
    assert failed_snapshot.fault_scope == :runtime_wide
    assert is_integer(failed_snapshot.finished_at)
    assert failed_snapshot.last_error == {:sequence_runner_exited, :boom}
  end
end
