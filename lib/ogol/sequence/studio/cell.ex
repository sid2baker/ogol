defmodule Ogol.Sequence.Studio.Cell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.Session.{RuntimeState, SequenceRunState}
  alias Ogol.Session.Workspace.SourceDraft
  alias Ogol.Studio.Cell
  alias Ogol.Studio.Cell.Control
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.Issue
  alias Ogol.Studio.Cell.Model
  alias Ogol.Studio.Cell.Notice
  alias Ogol.Studio.Cell.View

  @visual_compile_block_message "Resolve visual validation first or switch to Source."

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    runtime_status = Map.get(assigns, :runtime_status, default_runtime_status())
    session_runtime = Map.get(assigns, :session_runtime, %RuntimeState{})
    sequence_run = Map.get(assigns, :sequence_run, %SequenceRunState{})
    pending_intent = Map.get(assigns, :pending_intent, %{pause: %{}, abort: %{}})

    %Facts{
      artifact_id: Map.fetch!(assigns, :sequence_id),
      source: Map.fetch!(assigns, :draft_source),
      model: model_from_assigns(assigns),
      lifecycle_state:
        Cell.source_lifecycle(
          Map.fetch!(assigns, :current_source_digest),
          Map.get(runtime_status, :source_digest),
          compile_error?(runtime_status, Map.get(assigns, :sequence_draft))
        ),
      desired_state: desired_state(sequence_run),
      observed_state: observed_state(sequence_run),
      requested_view: normalize_view(Map.get(assigns, :requested_view, :visual)),
      issues:
        derive_issues(
          assigns,
          runtime_status,
          session_runtime,
          sequence_run,
          pending_intent,
          Map.get(assigns, :runtime_dirty?, false)
        )
    }
  end

  @spec default_runtime_status() :: map()
  def default_runtime_status do
    %{
      module: nil,
      source_digest: nil,
      blocked_reason: nil,
      lingering_pids: [],
      diagnostics: []
    }
  end

  @impl true
  @spec derive(Facts.t()) :: Derived.t()
  def derive(%Facts{} = facts) do
    visual_available? = facts.model.recovery != :unsupported

    {selected_view, views} =
      Cell.resolve_views(facts.requested_view, derive_views(visual_available?))

    %Derived{
      selected_view: selected_view,
      notice: notice_from_state(facts),
      controls: derive_controls(facts, selected_view),
      views: views
    }
  end

  defp model_from_assigns(assigns) do
    case Map.get(assigns, :sync_state, :synced) do
      :synced ->
        %Model{
          value: Map.get(assigns, :sequence_model),
          recovery: :full,
          diagnostics: []
        }

      :unsupported ->
        %Model{
          value: nil,
          recovery: :unsupported,
          diagnostics: List.wrap(Map.get(assigns, :sync_diagnostics, []))
        }
    end
  end

  defp desired_state(%SequenceRunState{status: status}) when status in [:starting, :running],
    do: :running

  defp desired_state(%SequenceRunState{status: :held}), do: :running

  defp desired_state(_sequence_run), do: :idle

  defp observed_state(%SequenceRunState{status: status}) when status in [:starting, :running],
    do: :running

  defp observed_state(%SequenceRunState{status: :held}), do: :degraded

  defp observed_state(_sequence_run), do: :idle

  defp derive_views(visual_available?) do
    [
      %View{id: :visual, label: "Visual", available?: visual_available?},
      %View{id: :source, label: "Source", available?: true},
      %View{id: :live, label: "Live", available?: true}
    ]
  end

  defp derive_controls(%Facts{} = facts, selected_view) do
    read_only? = Enum.any?(facts.issues, &match?(%Issue{id: :revision_read_only}, &1))
    run_active? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_running}, &1))
    run_paused? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_paused}, &1))
    run_held? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_held}, &1))
    run_completed? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_completed}, &1))
    run_aborted? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_aborted}, &1))
    run_faulted? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_faulted}, &1))
    held_resumable? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_held_resumable}, &1))
    pause_requested? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_pause_requested}, &1))
    abort_requested? = Enum.any?(facts.issues, &match?(%Issue{id: :sequence_abort_requested}, &1))
    auto_mode_required? = Enum.any?(facts.issues, &match?(%Issue{id: :auto_mode_required}, &1))
    cycle_policy? = Enum.any?(facts.issues, &match?(%Issue{id: :run_policy_cycle}, &1))
    terminal_result? = run_completed? or run_aborted? or run_faulted?
    sequence_owned? = run_active? or run_paused? or run_held?

    compile_control =
      Cell.module_compile_control(
        :sequence,
        facts,
        variant: :secondary,
        enabled?: not read_only? and compile_enabled?(facts, selected_view),
        disabled_reason: compile_disabled_reason(facts, selected_view, read_only?)
      )

    delete_control =
      Cell.delete_control(
        :sequence,
        facts,
        enabled?: not read_only? and not sequence_owned?,
        disabled_reason: delete_disabled_reason(read_only?, sequence_owned?)
      )

    mode_controls =
      if sequence_owned? do
        []
      else
        case auto_mode_required? do
          true ->
            [
              %Control{
                id: :arm_auto,
                label: "Arm Auto",
                variant: :secondary,
                enabled?: true,
                operation: {:set_control_mode, :auto}
              }
            ]

          false ->
            [
              %Control{
                id: :manual,
                label: "Manual",
                variant: :secondary,
                enabled?: true,
                operation: {:set_control_mode, :manual}
              }
            ]
        end
      end

    policy_controls =
      if sequence_owned? do
        []
      else
        case cycle_policy? do
          true ->
            [
              %Control{
                id: :set_once_policy,
                label: "Once",
                variant: :secondary,
                enabled?: true,
                operation: {:set_sequence_run_policy, :once}
              }
            ]

          false ->
            [
              %Control{
                id: :set_cycle_policy,
                label: "Cycle",
                variant: :secondary,
                enabled?: true,
                operation: {:set_sequence_run_policy, :cycle}
              }
            ]
        end
      end

    run_controls =
      if sequence_owned? do
        cond do
          abort_requested? ->
            [
              %Control{
                id: :cancel,
                label: "Aborting...",
                variant: :primary,
                enabled?: false,
                disabled_reason:
                  "Abort is pending until the current step reaches a safe boundary.",
                operation: nil
              }
            ]

          pause_requested? ->
            [
              %Control{
                id: :pause,
                label: "Pausing...",
                variant: :secondary,
                enabled?: false,
                disabled_reason:
                  "Pause is pending until the current step reaches a safe boundary.",
                operation: nil
              },
              %Control{
                id: :cancel,
                label: "Cancel",
                variant: :primary,
                enabled?: true,
                operation: :cancel_sequence_run
              }
            ]

          run_paused? ->
            [
              %Control{
                id: :resume,
                label: "Resume",
                variant: :secondary,
                enabled?: true,
                operation: :resume_sequence_run
              },
              %Control{
                id: :cancel,
                label: "Cancel",
                variant: :primary,
                enabled?: true,
                operation: :cancel_sequence_run
              }
            ]

          run_held? and held_resumable? ->
            [
              %Control{
                id: :resume,
                label: "Resume",
                variant: :secondary,
                enabled?: true,
                operation: :resume_sequence_run
              },
              acknowledge_control("Acknowledge")
            ]

          run_held? ->
            [acknowledge_control("Acknowledge")]

          true ->
            [
              %Control{
                id: :pause,
                label: "Pause",
                variant: :secondary,
                enabled?: true,
                operation: :pause_sequence_run
              },
              %Control{
                id: :cancel,
                label: "Cancel",
                variant: :primary,
                enabled?: true,
                operation: :cancel_sequence_run
              }
            ]
        end
      else
        maybe_acknowledge_result_control(terminal_result?, run_faulted?, read_only?) ++
          [
            %Control{
              id: :run,
              label: if(cycle_policy?, do: "Run Cycle", else: "Run"),
              variant: :primary,
              enabled?: not read_only? and run_enabled?(facts, selected_view),
              disabled_reason: run_disabled_reason(facts, selected_view, read_only?),
              operation: run_operation(facts.artifact_id)
            }
          ]
      end

    [compile_control] ++ mode_controls ++ policy_controls ++ run_controls ++ [delete_control]
  end

  defp maybe_acknowledge_result_control(false, _run_faulted?, _read_only?), do: []

  defp maybe_acknowledge_result_control(true, true, read_only?) do
    [result_control("Acknowledge", :acknowledge_sequence_run, read_only?)]
  end

  defp maybe_acknowledge_result_control(true, false, read_only?) do
    [result_control("Clear", :clear_sequence_run_result, read_only?)]
  end

  defp acknowledge_control(label, read_only? \\ false) when is_binary(label) do
    result_control(label, :acknowledge_sequence_run, read_only?)
  end

  defp result_control(label, operation, read_only?)
       when is_binary(label) and is_atom(operation) do
    %Control{
      id: :acknowledge,
      label: label,
      variant: :secondary,
      enabled?: not read_only?,
      disabled_reason: if(read_only?, do: "Saved revisions are read-only."),
      operation: operation
    }
  end

  defp compile_enabled?(%Facts{} = facts, :visual) do
    not Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1))
  end

  defp compile_enabled?(_facts, _selected_view), do: true

  defp compile_disabled_reason(_facts, _selected_view, true), do: "Saved revisions are read-only."

  defp compile_disabled_reason(%Facts{} = facts, :visual, false) do
    if Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) do
      @visual_compile_block_message
    end
  end

  defp compile_disabled_reason(_facts, _selected_view, false), do: nil

  defp run_enabled?(%Facts{} = facts, :visual) do
    compile_run_ready?(facts) and
      not Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1))
  end

  defp run_enabled?(%Facts{} = facts, _selected_view), do: compile_run_ready?(facts)

  defp compile_run_ready?(%Facts{} = facts) do
    facts.lifecycle_state == :compiled and
      not Enum.any?(facts.issues, &run_blocking_issue?/1)
  end

  defp run_disabled_reason(_facts, _selected_view, true), do: "Saved revisions are read-only."

  defp run_disabled_reason(%Facts{} = facts, :visual, false) do
    cond do
      Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) ->
        @visual_compile_block_message

      true ->
        run_disabled_reason(facts, :source, false)
    end
  end

  defp run_disabled_reason(%Facts{} = facts, _selected_view, false) do
    cond do
      facts.artifact_id == nil ->
        "No sequence is selected."

      facts.lifecycle_state != :compiled ->
        "Compile the current source before running."

      Enum.any?(facts.issues, &match?(%Issue{id: :compile_failed}, &1)) ->
        "Resolve compile failures before running."

      Enum.any?(facts.issues, &match?(%Issue{id: :compile_blocked_old_code}, &1)) ->
        "Old sequence code is still in use. Retry once it drains."

      Enum.any?(facts.issues, &match?(%Issue{id: :compile_runtime_failed}, &1)) ->
        "Compile the current source successfully before running."

      Enum.any?(facts.issues, &match?(%Issue{id: :compiled_stale}, &1)) ->
        "Recompile the current source before running."

      Enum.any?(facts.issues, &match?(%Issue{id: :runtime_not_running}, &1)) ->
        "Start the active topology before running a sequence."

      Enum.any?(facts.issues, &match?(%Issue{id: :runtime_dirty}, &1)) ->
        "The active topology no longer matches the workspace. Apply it first."

      Enum.any?(facts.issues, &match?(%Issue{id: :runtime_topology_mismatch}, &1)) ->
        "The active topology does not match this sequence."

      Enum.any?(facts.issues, &match?(%Issue{id: :other_sequence_running}, &1)) ->
        "Another sequence is already running."

      Enum.any?(facts.issues, &match?(%Issue{id: :auto_mode_required}, &1)) ->
        "Arm Auto before running a sequence."

      true ->
        nil
    end
  end

  defp delete_disabled_reason(true, _run_active?), do: "Saved revisions are read-only."
  defp delete_disabled_reason(false, true), do: "Cancel the running sequence before deleting it."
  defp delete_disabled_reason(false, false), do: nil

  defp derive_issues(
         assigns,
         runtime_status,
         session_runtime,
         sequence_run,
         pending_intent,
         runtime_dirty?
       ) do
    current_sequence_id = Map.get(assigns, :sequence_id)

    [
      current_sequence_run_issue(sequence_run, current_sequence_id),
      sequence_held_resumable_issue(sequence_run, current_sequence_id, session_runtime),
      sequence_pause_requested_issue(sequence_run, current_sequence_id, pending_intent),
      sequence_abort_requested_issue(sequence_run, current_sequence_id, pending_intent),
      run_policy_issue(sequence_run),
      other_sequence_running_issue(sequence_run, current_sequence_id),
      auto_mode_required_issue(assigns, sequence_run),
      runtime_not_running_issue(session_runtime),
      runtime_dirty_issue(session_runtime, runtime_dirty?),
      runtime_topology_mismatch_issue(assigns, session_runtime),
      model_issue(model_from_assigns(assigns)),
      compile_issue(runtime_status),
      stale_issue(
        Map.fetch!(assigns, :current_source_digest),
        runtime_status,
        Map.get(assigns, :sequence_draft)
      ),
      manual_issue(Map.get(assigns, :sequence_issue)),
      runtime_issue(runtime_status)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp current_sequence_run_issue(
         %SequenceRunState{sequence_id: sequence_id, status: status} = run,
         current_sequence_id
       )
       when sequence_id == current_sequence_id and status in [:starting, :running] do
    %Issue{
      id: :sequence_running,
      detail: %{
        status: status,
        step: run.current_step_label,
        procedure: run.current_procedure
      }
    }
  end

  defp current_sequence_run_issue(
         %SequenceRunState{sequence_id: sequence_id, status: :paused} = run,
         current_sequence_id
       )
       when sequence_id == current_sequence_id do
    %Issue{
      id: :sequence_paused,
      detail: %{
        step: run.current_step_label,
        procedure: run.current_procedure
      }
    }
  end

  defp current_sequence_run_issue(
         %SequenceRunState{sequence_id: sequence_id, status: :completed} = run,
         current_sequence_id
       )
       when sequence_id == current_sequence_id do
    %Issue{id: :sequence_completed, detail: %{finished_at: run.finished_at}}
  end

  defp current_sequence_run_issue(
         %SequenceRunState{sequence_id: sequence_id, status: :faulted} = run,
         current_sequence_id
       )
       when sequence_id == current_sequence_id do
    %Issue{id: :sequence_faulted, detail: fault_detail(run)}
  end

  defp current_sequence_run_issue(
         %SequenceRunState{sequence_id: sequence_id, status: :aborted},
         current_sequence_id
       )
       when sequence_id == current_sequence_id do
    %Issue{id: :sequence_aborted, detail: nil}
  end

  defp current_sequence_run_issue(
         %SequenceRunState{sequence_id: sequence_id, status: :held} = run,
         current_sequence_id
       )
       when sequence_id == current_sequence_id do
    %Issue{id: :sequence_held, detail: fault_detail(run)}
  end

  defp current_sequence_run_issue(_sequence_run, _current_sequence_id), do: nil

  defp sequence_abort_requested_issue(
         %SequenceRunState{sequence_id: sequence_id, status: status},
         current_sequence_id,
         %{abort: %{admitted?: true, fulfilled?: false}}
       )
       when sequence_id == current_sequence_id and status in [:starting, :running] do
    %Issue{
      id: :sequence_abort_requested,
      detail: "Abort will take effect at the next safe boundary."
    }
  end

  defp sequence_abort_requested_issue(_sequence_run, _current_sequence_id, _pending_intent),
    do: nil

  defp sequence_held_resumable_issue(
         %SequenceRunState{
           sequence_id: sequence_id,
           status: :held,
           resumable?: true,
           resume_blockers: blockers
         },
         current_sequence_id,
         %RuntimeState{trust_state: :trusted, observed: observed}
       )
       when sequence_id == current_sequence_id and blockers in [[], nil] and
              observed in [{:running, :simulation}, {:running, :live}] do
    %Issue{
      id: :sequence_held_resumable,
      detail: "Runtime trust is restored. Resume continues from the last committed boundary."
    }
  end

  defp sequence_held_resumable_issue(_sequence_run, _current_sequence_id, _session_runtime),
    do: nil

  defp sequence_pause_requested_issue(
         %SequenceRunState{sequence_id: sequence_id, status: :running},
         current_sequence_id,
         %{pause: %{admitted?: true, fulfilled?: false}}
       )
       when sequence_id == current_sequence_id do
    %Issue{
      id: :sequence_pause_requested,
      detail: "Pause will take effect at the next safe boundary."
    }
  end

  defp sequence_pause_requested_issue(_sequence_run, _current_sequence_id, _pending_intent),
    do: nil

  defp other_sequence_running_issue(
         %SequenceRunState{status: status, sequence_id: sequence_id},
         current_sequence_id
       )
       when status in [:starting, :running, :paused, :held] and is_binary(sequence_id) and
              sequence_id != current_sequence_id do
    %Issue{id: :other_sequence_running, detail: sequence_id}
  end

  defp other_sequence_running_issue(_sequence_run, _current_sequence_id), do: nil

  defp run_policy_issue(%SequenceRunState{policy: :cycle}),
    do: %Issue{id: :run_policy_cycle, detail: "Cycle mode selected."}

  defp run_policy_issue(_sequence_run), do: nil

  defp fault_detail(%SequenceRunState{} = run) do
    %{
      error: run.last_error,
      source: run.fault_source,
      recoverability: run.fault_recoverability,
      scope: run.fault_scope
    }
  end

  defp auto_mode_required_issue(%{control_mode: :manual}, %SequenceRunState{status: status})
       when status not in [:starting, :running, :paused] do
    %Issue{id: :auto_mode_required, detail: "Arm Auto before running a sequence."}
  end

  defp auto_mode_required_issue(_assigns, _sequence_run), do: nil

  defp runtime_not_running_issue(%RuntimeState{observed: observed})
       when observed not in [{:running, :simulation}, {:running, :live}] do
    %Issue{
      id: :runtime_not_running,
      detail: "Start the active topology before running a sequence."
    }
  end

  defp runtime_not_running_issue(_session_runtime), do: nil

  defp runtime_dirty_issue(%RuntimeState{observed: observed}, true)
       when observed in [{:running, :simulation}, {:running, :live}] do
    %Issue{id: :runtime_dirty, detail: "The active topology no longer matches the workspace."}
  end

  defp runtime_dirty_issue(_session_runtime, _runtime_dirty?), do: nil

  defp runtime_topology_mismatch_issue(assigns, %RuntimeState{
         active_topology_module: active_topology_module,
         observed: observed
       })
       when observed in [{:running, :simulation}, {:running, :live}] and
              is_atom(active_topology_module) do
    expected =
      case Map.get(assigns, :sequence_model) do
        %{topology_module_name: topology_module_name} when is_binary(topology_module_name) ->
          topology_module_name

        _other ->
          nil
      end

    active =
      active_topology_module
      |> Atom.to_string()
      |> String.trim_leading("Elixir.")

    if is_binary(expected) and expected != active do
      %Issue{id: :runtime_topology_mismatch, detail: %{expected: expected, actual: active}}
    end
  end

  defp runtime_topology_mismatch_issue(_assigns, _session_runtime), do: nil

  defp model_issue(%Model{recovery: :unsupported, diagnostics: diagnostics}) do
    %Issue{id: :visual_unavailable, detail: Enum.join(diagnostics, " ")}
  end

  defp model_issue(_model), do: nil

  defp compile_issue(%{diagnostics: [first | _]}) do
    %Issue{id: :compile_failed, detail: first}
  end

  defp compile_issue(_runtime_status), do: nil

  defp stale_issue(source_digest, runtime_status, %SourceDraft{} = draft) do
    if not compile_error?(runtime_status, draft) and
         Cell.source_stale?(source_digest, Map.get(runtime_status, :source_digest)) do
      %Issue{id: :compiled_stale, detail: "The source changed after the last successful compile."}
    end
  end

  defp stale_issue(_source_digest, _runtime_status, _draft), do: nil

  defp manual_issue(nil), do: nil
  defp manual_issue({id, detail}), do: %Issue{id: id, detail: detail}

  defp runtime_issue(%{blocked_reason: :old_code_in_use, lingering_pids: pids}) do
    %Issue{id: :compile_blocked_old_code, detail: %{count: length(List.wrap(pids))}}
  end

  defp runtime_issue(%{blocked_reason: reason}) when not is_nil(reason) do
    %Issue{id: :compile_runtime_failed, detail: inspect(reason)}
  end

  defp runtime_issue(_runtime_status), do: nil

  defp run_blocking_issue?(%Issue{id: id})
       when id in [
              :auto_mode_required,
              :compile_failed,
              :compile_blocked_old_code,
              :compile_runtime_failed,
              :compiled_stale,
              :runtime_not_running,
              :runtime_dirty,
              :runtime_topology_mismatch,
              :other_sequence_running
            ],
       do: true

  defp run_blocking_issue?(_issue), do: false

  defp notice_from_state(%Facts{issues: issues, lifecycle_state: lifecycle_state}) do
    case prioritize_issues(issues) do
      [issue | _rest] ->
        notice_from_issue(issue)

      [] when lifecycle_state == :compiled ->
        %Notice{
          tone: :good,
          title: "Compiled",
          message: "The current source compiled into a canonical sequence model."
        }

      _other ->
        nil
    end
  end

  defp prioritize_issues(issues), do: Enum.sort_by(issues, &issue_priority/1)

  defp issue_priority(%Issue{id: :sequence_faulted}), do: 0
  defp issue_priority(%Issue{id: :sequence_running}), do: 1
  defp issue_priority(%Issue{id: :sequence_paused}), do: 2
  defp issue_priority(%Issue{id: :sequence_held}), do: 3
  defp issue_priority(%Issue{id: :sequence_pause_requested}), do: 4
  defp issue_priority(%Issue{id: :sequence_abort_requested}), do: 5
  defp issue_priority(%Issue{id: :sequence_completed}), do: 4
  defp issue_priority(%Issue{id: :sequence_aborted}), do: 5
  defp issue_priority(%Issue{id: :other_sequence_running}), do: 6
  defp issue_priority(%Issue{id: :compile_failed}), do: 7
  defp issue_priority(%Issue{id: :compile_blocked_old_code}), do: 8
  defp issue_priority(%Issue{id: :compile_runtime_failed}), do: 9
  defp issue_priority(%Issue{id: :visual_edit_failed}), do: 10
  defp issue_priority(%Issue{id: :visual_unavailable}), do: 11
  defp issue_priority(%Issue{id: :compiled_stale}), do: 12
  defp issue_priority(%Issue{id: :runtime_dirty}), do: 13
  defp issue_priority(%Issue{id: :runtime_topology_mismatch}), do: 14
  defp issue_priority(%Issue{id: :runtime_not_running}), do: 15
  defp issue_priority(%Issue{id: :auto_mode_required}), do: 16
  defp issue_priority(%Issue{id: :revision_read_only}), do: 17
  defp issue_priority(_issue), do: 100

  defp notice_from_issue(%Issue{id: :sequence_faulted, detail: detail}) do
    %Notice{tone: :error, title: "Sequence faulted", message: faulted_detail(detail)}
  end

  defp notice_from_issue(%Issue{id: :sequence_running, detail: detail}) do
    message =
      case detail do
        %{step: step, procedure: procedure} when is_binary(step) and is_binary(procedure) ->
          "Running #{procedure} :: #{step}"

        %{step: step} when is_binary(step) ->
          "Running #{step}"

        _other ->
          "Sequence run is active."
      end

    %Notice{tone: :info, title: "Running", message: message}
  end

  defp notice_from_issue(%Issue{id: :sequence_paused, detail: detail}) do
    %Notice{tone: :info, title: "Paused", message: paused_detail(detail)}
  end

  defp notice_from_issue(%Issue{id: :sequence_pause_requested, detail: message}) do
    %Notice{tone: :info, title: "Pause requested", message: message}
  end

  defp notice_from_issue(%Issue{id: :sequence_abort_requested, detail: message}) do
    %Notice{tone: :warning, title: "Abort requested", message: message}
  end

  defp notice_from_issue(%Issue{id: :run_policy_cycle, detail: message}) do
    %Notice{tone: :info, title: "Cycle mode", message: message}
  end

  defp notice_from_issue(%Issue{id: :sequence_held, detail: detail}) do
    %Notice{
      tone: :warning,
      title: "Held",
      message: held_detail(detail)
    }
  end

  defp notice_from_issue(%Issue{id: :sequence_completed}) do
    %Notice{
      tone: :good,
      title: "Completed",
      message: "The latest sequence run finished successfully."
    }
  end

  defp notice_from_issue(%Issue{id: :sequence_aborted}) do
    %Notice{tone: :warning, title: "Aborted", message: "The latest sequence run was aborted."}
  end

  defp notice_from_issue(%Issue{id: :auto_mode_required, detail: message}) do
    %Notice{tone: :info, title: "Auto mode required", message: message}
  end

  defp notice_from_issue(%Issue{id: :other_sequence_running, detail: sequence_id}) do
    %Notice{
      tone: :warning,
      title: "Another sequence is running",
      message: "#{sequence_id} is already active on the current topology."
    }
  end

  defp notice_from_issue(%Issue{id: :compile_failed, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :compile_blocked_old_code, detail: %{count: count}}) do
    noun = if count == 1, do: "process", else: "processes"

    %Notice{
      tone: :warning,
      title: "Compile blocked",
      message: "Old sequence code is still in use by #{count} #{noun}. Retry once it drains."
    }
  end

  defp notice_from_issue(%Issue{id: :compile_runtime_failed, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :compiled_stale, detail: message}) do
    %Notice{tone: :warning, title: "Compiled output is stale", message: message}
  end

  defp notice_from_issue(%Issue{id: :runtime_dirty, detail: message}) do
    %Notice{tone: :warning, title: "Topology is out of date", message: message}
  end

  defp notice_from_issue(%Issue{
         id: :runtime_topology_mismatch,
         detail: %{expected: expected, actual: actual}
       }) do
    %Notice{
      tone: :warning,
      title: "Topology mismatch",
      message: "Sequence expects #{expected}, but #{actual} is active."
    }
  end

  defp notice_from_issue(%Issue{id: :runtime_not_running, detail: message}) do
    %Notice{tone: :info, title: "Topology not running", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_unavailable, detail: message}) do
    %Notice{tone: :error, title: "Visual summary unavailable", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_edit_failed, detail: message}) do
    %Notice{tone: :error, title: "Visual edit failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :revision_read_only, detail: message}) do
    %Notice{tone: :warning, title: "Saved revision", message: message}
  end

  defp compile_error?(runtime_status, _draft) do
    Map.get(runtime_status, :diagnostics, []) != [] or
      not is_nil(Map.get(runtime_status, :blocked_reason))
  end

  defp normalize_view(view) when view in [:visual, :source, :live], do: view
  defp normalize_view("visual"), do: :visual
  defp normalize_view("source"), do: :source
  defp normalize_view("live"), do: :live
  defp normalize_view(_other), do: :source

  defp run_operation(id) when is_binary(id), do: {:start_sequence_run, id}
  defp run_operation(_id), do: nil

  defp stringify_detail(message) when is_binary(message), do: message
  defp stringify_detail(message), do: inspect(message)

  defp paused_detail(%{step: step, procedure: procedure})
       when is_binary(step) and is_binary(procedure) do
    "Paused after #{procedure} :: #{step}. Resume continues from the last committed boundary."
  end

  defp paused_detail(%{step: step}) when is_binary(step) do
    "Paused after #{step}. Resume continues from the last committed boundary."
  end

  defp paused_detail(_detail) do
    "Paused at a committed boundary. Resume continues from the last committed boundary."
  end

  defp held_detail({:trust_invalidated, reasons}) when is_list(reasons) do
    "Sequence run is held because runtime trust was invalidated: #{Enum.map_join(reasons, ", ", &inspect/1)}"
  end

  defp held_detail(%{error: {:trust_invalidated, reasons}}) when is_list(reasons) do
    held_detail({:trust_invalidated, reasons})
  end

  defp held_detail(message) when is_binary(message), do: message
  defp held_detail(message), do: "Sequence run is held: #{inspect(message)}"

  defp faulted_detail(%{
         error: error,
         source: source,
         recoverability: recoverability,
         scope: scope
       }) do
    "#{stringify_detail(error)} (source=#{inspect(source)}, recoverability=#{inspect(recoverability)}, scope=#{inspect(scope)})"
  end

  defp faulted_detail(message), do: stringify_detail(message)
end
