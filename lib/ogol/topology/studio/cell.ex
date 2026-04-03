defmodule Ogol.Topology.Studio.Cell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.Studio.Cell
  alias Ogol.Studio.Cell.Control
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.Issue
  alias Ogol.Studio.Cell.Model
  alias Ogol.Studio.Cell.Notice
  alias Ogol.Studio.Cell.View
  alias Ogol.Session.Workspace.SourceDraft

  @visual_compile_block_message "Resolve visual validation first or switch to Source."

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    runtime_status = Map.get(assigns, :runtime_status, default_runtime_status())

    %Facts{
      artifact_id: Map.fetch!(assigns, :topology_artifact_id),
      source: Map.fetch!(assigns, :draft_source),
      model: model_from_assigns(assigns),
      lifecycle_state:
        lifecycle_state(
          Map.fetch!(assigns, :current_source_digest),
          runtime_status,
          Map.get(assigns, :topology_draft)
        ),
      desired_state: desired_state(runtime_status),
      observed_state: observed_state(runtime_status),
      requested_view: normalize_view(Map.get(assigns, :requested_view, :source)),
      issues: derive_issues(assigns, runtime_status)
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
      notice: notice_from_issues(facts.issues),
      controls: derive_controls(facts, selected_view),
      views: views
    }
  end

  @spec default_runtime_status() :: map()
  def default_runtime_status do
    %{
      selected_module: nil,
      active: nil,
      selected_running?: false,
      other_running?: false,
      desired: :stopped,
      observed: :stopped,
      runtime_status: :idle,
      realized?: true,
      dirty?: false,
      source_digest: nil,
      blocked_reason: nil,
      lingering_pids: [],
      diagnostics: []
    }
  end

  defp model_from_assigns(assigns) do
    case Map.get(assigns, :sync_state, :synced) do
      :synced ->
        %Model{
          value: Map.get(assigns, :topology_model),
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

  defp normalize_view(view) when view in [:visual, :source, :live], do: view
  defp normalize_view("visual"), do: :visual
  defp normalize_view("source"), do: :source
  defp normalize_view("live"), do: :live
  defp normalize_view(_other), do: :source

  defp lifecycle_state(source_digest, runtime_status, %SourceDraft{} = draft) do
    Cell.source_lifecycle(
      source_digest,
      Map.get(runtime_status, :source_digest),
      compile_error?(runtime_status, draft)
    )
  end

  defp lifecycle_state(source_digest, runtime_status, _draft) do
    Cell.source_lifecycle(source_digest, Map.get(runtime_status, :source_digest), false)
  end

  defp desired_state(%{desired: {:running, _mode}}), do: :running
  defp desired_state(%{desired: :stopped}), do: :idle
  defp desired_state(_runtime_status), do: nil

  defp observed_state(%{selected_running?: true}), do: :running
  defp observed_state(%{other_running?: true}), do: :degraded
  defp observed_state(_runtime_status), do: :idle

  defp derive_views(visual_available?) do
    [
      %View{id: :visual, label: "Visual", available?: visual_available?},
      %View{id: :source, label: "Source", available?: true},
      %View{id: :live, label: "Live", available?: true}
    ]
  end

  defp derive_controls(%Facts{} = facts, selected_view) do
    compile_enabled? = compile_enabled?(facts, selected_view)

    compile_control =
      Cell.module_compile_control(
        :topology,
        facts,
        variant: :secondary,
        enabled?: compile_enabled?,
        disabled_reason: compile_disabled_reason(facts, selected_view)
      )

    if facts.observed_state == :running do
      [
        compile_control,
        %Control{
          id: :apply,
          label: "Apply",
          variant: :secondary,
          enabled?: true,
          operation: {:set_desired_runtime, {:running, :live}}
        },
        %Control{
          id: :stop,
          label: "Stop",
          variant: :primary,
          enabled?: true,
          operation: {:set_desired_runtime, :stopped}
        }
      ]
    else
      [
        compile_control,
        %Control{
          id: :start,
          label: "Start",
          variant: :primary,
          enabled?: start_enabled?(facts, selected_view),
          disabled_reason: start_disabled_reason(facts, selected_view),
          operation: {:set_desired_runtime, {:running, :live}}
        }
      ]
    end
  end

  defp compile_enabled?(%Facts{} = facts, :visual) do
    not Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1))
  end

  defp compile_enabled?(_facts, _selected_view), do: true

  defp compile_disabled_reason(%Facts{} = facts, :visual) do
    cond do
      Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) ->
        @visual_compile_block_message

      true ->
        nil
    end
  end

  defp compile_disabled_reason(%Facts{} = _facts, _selected_view), do: nil

  defp start_enabled?(%Facts{} = facts, :visual) do
    not Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1))
  end

  defp start_enabled?(%Facts{} = _facts, _selected_view), do: true

  defp start_disabled_reason(%Facts{} = facts, :visual) do
    cond do
      Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) ->
        @visual_compile_block_message

      true ->
        nil
    end
  end

  defp start_disabled_reason(%Facts{} = _facts, _selected_view), do: nil

  defp derive_issues(assigns, runtime_status) do
    requested_view = normalize_view(Map.get(assigns, :requested_view, :source))
    model = model_from_assigns(assigns)
    current_source_digest = Map.fetch!(assigns, :current_source_digest)
    draft = Map.get(assigns, :topology_draft)

    [
      feedback_issue(Map.get(assigns, :studio_feedback)),
      validation_issue(Map.get(assigns, :validation_errors, []), requested_view),
      model_issue(model),
      stale_issue(current_source_digest, runtime_status, draft),
      compile_issue(draft),
      runtime_issue(runtime_status)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp validation_issue([], _requested_view), do: nil
  defp validation_issue([first | _], :visual), do: %Issue{id: :visual_invalid, detail: first}
  defp validation_issue(_errors, _requested_view), do: nil

  defp model_issue(%Model{recovery: :unsupported, diagnostics: diagnostics}) do
    %Issue{id: :visual_unavailable, detail: Enum.join(diagnostics, " ")}
  end

  defp model_issue(_model), do: nil

  defp stale_issue(current_source_digest, runtime_status, %SourceDraft{} = draft) do
    if not compile_error?(runtime_status, draft) and
         Cell.source_stale?(current_source_digest, Map.get(runtime_status, :source_digest)) do
      %Issue{id: :compiled_stale, detail: "The source changed after the last successful compile."}
    end
  end

  defp stale_issue(_current_source_digest, _runtime_status, _draft), do: nil

  defp compile_issue(%{diagnostics: [first | _]}) do
    %Issue{id: :compile_failed, detail: first}
  end

  defp compile_issue(_runtime_status), do: nil

  defp runtime_issue(%{blocked_reason: :old_code_in_use, lingering_pids: pids}) do
    %Issue{id: :compile_blocked_old_code, detail: %{count: length(List.wrap(pids))}}
  end

  defp runtime_issue(%{blocked_reason: {:module_mismatch, expected, actual}}) do
    %Issue{id: :compile_module_mismatch, detail: %{expected: expected, actual: actual}}
  end

  defp runtime_issue(%{blocked_reason: reason}) when not is_nil(reason) do
    %Issue{id: :compile_runtime_failed, detail: inspect(reason)}
  end

  defp runtime_issue(%{selected_running?: true, dirty?: true}) do
    %Issue{id: :running_outdated, detail: nil}
  end

  defp runtime_issue(%{selected_running?: true, active: %{topology_scope: topology_scope}}) do
    %Issue{id: :running_selected, detail: humanize_id(Atom.to_string(topology_scope))}
  end

  defp runtime_issue(%{other_running?: true, active: %{topology_scope: topology_scope}}) do
    %Issue{id: :other_topology_running, detail: humanize_id(Atom.to_string(topology_scope))}
  end

  defp runtime_issue(%{selected_module: nil}) do
    %Issue{id: :missing_module, detail: nil}
  end

  defp runtime_issue(_runtime_status), do: nil

  defp feedback_issue(%{level: level, title: title, detail: detail})
       when level in [:warning, :error] do
    %Issue{id: :feedback, detail: %{tone: level, title: title, detail: detail}}
  end

  defp feedback_issue(_feedback), do: nil

  defp notice_from_issues(issues) do
    issues
    |> Enum.sort_by(&issue_priority/1)
    |> case do
      [issue | _] -> notice_from_issue(issue)
      [] -> nil
    end
  end

  defp issue_priority(%Issue{id: :feedback}), do: 0
  defp issue_priority(%Issue{id: :compile_failed}), do: 1
  defp issue_priority(%Issue{id: :compile_blocked_old_code}), do: 2
  defp issue_priority(%Issue{id: :compile_module_mismatch}), do: 3
  defp issue_priority(%Issue{id: :compile_runtime_failed}), do: 4
  defp issue_priority(%Issue{id: :compiled_stale}), do: 5
  defp issue_priority(%Issue{id: :visual_invalid}), do: 6
  defp issue_priority(%Issue{id: :visual_unavailable}), do: 7
  defp issue_priority(%Issue{id: :other_topology_running}), do: 8
  defp issue_priority(%Issue{id: :running_outdated}), do: 9
  defp issue_priority(%Issue{id: :running_selected}), do: 10
  defp issue_priority(%Issue{id: :missing_module}), do: 11
  defp issue_priority(_issue), do: 100

  defp notice_from_issue(%Issue{
         id: :feedback,
         detail: %{tone: tone, title: title, detail: detail}
       }) do
    %Notice{tone: tone, title: title, message: detail}
  end

  defp notice_from_issue(%Issue{id: :compile_failed, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :compile_blocked_old_code, detail: %{count: count}}) do
    noun = if count == 1, do: "process", else: "processes"

    %Notice{
      tone: :warning,
      title: "Compile blocked",
      message: "#{count} lingering #{noun} still use the previous topology module version."
    }
  end

  defp notice_from_issue(%Issue{
         id: :compile_module_mismatch,
         detail: %{expected: expected, actual: actual}
       }) do
    %Notice{
      tone: :error,
      title: "Compile blocked",
      message:
        "The selected topology id is already bound to #{inspect(expected)} and cannot switch to #{inspect(actual)} in latest-only mode."
    }
  end

  defp notice_from_issue(%Issue{id: :compile_runtime_failed, detail: message}) do
    %Notice{
      tone: :error,
      title: "Compile failed",
      message: "Runtime rejected the compiled topology artifact: #{message}"
    }
  end

  defp notice_from_issue(%Issue{id: :compiled_stale, detail: message}) do
    %Notice{tone: :warning, title: "Compiled output is stale", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_invalid, detail: message}) do
    %Notice{tone: :warning, title: "Visual update blocked", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_unavailable, detail: message}) do
    %Notice{tone: :error, title: "Visual editor unavailable", message: message}
  end

  defp notice_from_issue(%Issue{id: :other_topology_running, detail: root}) do
    %Notice{
      tone: :warning,
      title: "Another topology is active",
      message: "#{root} is currently running."
    }
  end

  defp notice_from_issue(%Issue{id: :running_outdated}) do
    %Notice{
      tone: :warning,
      title: "Runtime differs from workspace",
      message:
        "The running topology still reflects an older workspace state. Compile and Apply to realize the current workspace."
    }
  end

  defp notice_from_issue(%Issue{id: :running_selected, detail: root}) do
    %Notice{
      tone: :info,
      title: "Running",
      message: "#{root} is active."
    }
  end

  defp notice_from_issue(%Issue{id: :missing_module}) do
    %Notice{
      tone: :error,
      title: "Compile failed",
      message: "Source must define one topology module before it can be compiled."
    }
  end

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp compile_error?(runtime_status, _draft) do
    Map.get(runtime_status, :diagnostics, []) != [] or
      not is_nil(Map.get(runtime_status, :blocked_reason))
  end
end
