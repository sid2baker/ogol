defmodule Ogol.Session.RuntimeFaultPolicy do
  @moduledoc false

  alias Ogol.Session.SequenceRunState

  @spec external_runtime_failure(map(), term()) :: map()
  def external_runtime_failure(snapshot, reason) when is_map(snapshot) do
    snapshot
    |> Map.put(:fault_source, :external_runtime)
    |> Map.put(:fault_recoverability, :abort_required)
    |> Map.put(:fault_scope, :runtime_wide)
    |> Map.put(:resumable?, false)
    |> Map.put(:resume_blockers, [:terminal_state])
    |> Map.put(:finished_at, System.system_time(:millisecond))
    |> Map.put(:last_error, reason)
  end

  @spec external_runtime_hold(map(), [term()]) :: map()
  def external_runtime_hold(snapshot, reasons) when is_map(snapshot) and is_list(reasons) do
    blockers = runtime_resume_blockers(reasons)
    recoverability = external_runtime_hold_recoverability(snapshot, blockers)

    snapshot
    |> Map.put(:fault_source, :external_runtime)
    |> Map.put(:fault_recoverability, recoverability)
    |> Map.put(:fault_scope, :runtime_wide)
    |> apply_hold_resumability(blockers)
    |> Map.put(:finished_at, nil)
    |> Map.put(:last_error, {:trust_invalidated, reasons})
  end

  @spec external_runtime_invalidation(SequenceRunState.t(), [term()]) :: SequenceRunState.t()
  def external_runtime_invalidation(%SequenceRunState{} = run, reasons) when is_list(reasons) do
    blockers = runtime_resume_blockers(reasons)
    recoverability = external_runtime_hold_recoverability(run, blockers)

    %SequenceRunState{
      run
      | resumable?: blockers == [] and run.resumable?,
        resume_blockers: Enum.uniq(List.wrap(run.resume_blockers) ++ blockers),
        fault_source: :external_runtime,
        fault_recoverability: recoverability,
        fault_scope: :runtime_wide,
        last_error: {:trust_invalidated, reasons}
    }
  end

  @spec runtime_resume_blockers([term()]) :: [term()]
  def runtime_resume_blockers(reasons) when is_list(reasons) do
    Enum.reduce(reasons, [], fn
      :topology_generation_changed, acc -> [:topology_generation_changed | acc]
      :missing_topology_generation, acc -> [:missing_topology_generation | acc]
      :runtime_not_running, acc -> [:runtime_restart_requires_fresh_run | acc]
      {:runtime_failed, _reason}, acc -> [:runtime_restart_requires_fresh_run | acc]
      _other, acc -> acc
    end)
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp apply_hold_resumability(snapshot, resume_blockers)
       when is_map(snapshot) and is_list(resume_blockers) do
    if resume_blockers != [] do
      snapshot
      |> Map.put(:resumable?, false)
      |> Map.put(:resume_from_boundary, nil)
      |> Map.put(:resume_stack, nil)
      |> Map.put(:resume_blockers, resume_blockers)
    else
      snapshot
    end
  end

  defp external_runtime_hold_recoverability(subject, blockers)
       when is_map(subject) and is_list(blockers) do
    if blockers == [] and Map.get(subject, :resumable?, false) do
      :operator_ack_required
    else
      :abort_required
    end
  end
end
