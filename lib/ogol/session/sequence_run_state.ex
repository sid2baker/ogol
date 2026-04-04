defmodule Ogol.Session.SequenceRunState do
  @moduledoc false

  @type status :: :idle | :starting | :running | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          status: status(),
          sequence_id: String.t() | nil,
          sequence_module: module() | nil,
          run_id: String.t() | nil,
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
      when status in [:starting, :running, :completed, :failed, :cancelled] do
    %__MODULE__{
      status: status,
      sequence_id: Map.get(snapshot, :sequence_id),
      sequence_module: Map.get(snapshot, :sequence_module),
      run_id: Map.get(snapshot, :run_id),
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
