defmodule Ogol.Session.SequenceRunState do
  @moduledoc false

  @type status ::
          :idle | :starting | :running | :paused | :held | :completed | :aborted | :faulted

  @type run_policy :: :once | :cycle
  @type fault_source :: :machine | :sequence_logic | :external_runtime | nil
  @type fault_recoverability :: :automatic | :operator_ack_required | :abort_required | nil
  @type fault_scope :: :step_local | :run_wide | :runtime_wide | nil

  @type t :: %__MODULE__{
          status: status(),
          sequence_id: String.t() | nil,
          sequence_module: module() | nil,
          run_id: String.t() | nil,
          policy: run_policy(),
          cycle_count: non_neg_integer(),
          fault_source: fault_source(),
          fault_recoverability: fault_recoverability(),
          fault_scope: fault_scope(),
          resumable?: boolean(),
          resume_from_boundary: String.t() | nil,
          resume_blockers: [term()],
          run_generation: String.t() | nil,
          deployment_id: String.t() | nil,
          topology_module: module() | nil,
          current_procedure: String.t() | nil,
          current_step_id: String.t() | nil,
          current_step_label: String.t() | nil,
          started_at: integer() | nil,
          finished_at: integer() | nil,
          last_error: term() | nil
        }

  defstruct status: :idle,
            sequence_id: nil,
            sequence_module: nil,
            run_id: nil,
            policy: :once,
            cycle_count: 0,
            fault_source: nil,
            fault_recoverability: nil,
            fault_scope: nil,
            resumable?: false,
            resume_from_boundary: nil,
            resume_blockers: [],
            run_generation: nil,
            deployment_id: nil,
            topology_module: nil,
            current_procedure: nil,
            current_step_id: nil,
            current_step_label: nil,
            started_at: nil,
            finished_at: nil,
            last_error: nil

  @spec from_snapshot(status(), map()) :: t()
  def from_snapshot(status, snapshot)
      when status in [:starting, :running, :paused, :held, :completed, :aborted, :faulted] do
    %__MODULE__{
      status: status,
      sequence_id: Map.get(snapshot, :sequence_id),
      sequence_module: Map.get(snapshot, :sequence_module),
      run_id: Map.get(snapshot, :run_id),
      policy: Map.get(snapshot, :policy, :once),
      cycle_count: Map.get(snapshot, :cycle_count, 0),
      fault_source: Map.get(snapshot, :fault_source),
      fault_recoverability: Map.get(snapshot, :fault_recoverability),
      fault_scope: Map.get(snapshot, :fault_scope),
      resumable?: Map.get(snapshot, :resumable?, false),
      resume_from_boundary: Map.get(snapshot, :resume_from_boundary),
      resume_blockers: List.wrap(Map.get(snapshot, :resume_blockers, [])),
      run_generation: Map.get(snapshot, :run_generation),
      deployment_id: Map.get(snapshot, :deployment_id),
      topology_module: Map.get(snapshot, :topology_module),
      current_procedure: Map.get(snapshot, :current_procedure),
      current_step_id: Map.get(snapshot, :current_step_id),
      current_step_label: Map.get(snapshot, :current_step_label),
      started_at: Map.get(snapshot, :started_at),
      finished_at: Map.get(snapshot, :finished_at),
      last_error: Map.get(snapshot, :last_error)
    }
  end
end
