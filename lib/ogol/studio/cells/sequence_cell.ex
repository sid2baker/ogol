defmodule Ogol.Studio.SequenceCell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.Studio.Cell
  alias Ogol.Studio.Cell.Action
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.Issue
  alias Ogol.Studio.Cell.Model
  alias Ogol.Studio.Cell.Notice
  alias Ogol.Studio.Cell.View
  alias Ogol.Studio.WorkspaceStore.SequenceDraft

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    runtime_status = Map.get(assigns, :runtime_status, default_runtime_status())

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
      desired_state: nil,
      observed_state: nil,
      requested_view: normalize_view(Map.get(assigns, :requested_view, :visual)),
      issues: derive_issues(assigns)
    }
  end

  @spec default_runtime_status() :: map()
  def default_runtime_status do
    %{
      module: nil,
      source_digest: nil,
      blocked_reason: nil,
      lingering_pids: []
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
      actions: derive_actions(facts),
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

  defp derive_views(visual_available?) do
    [
      %View{id: :visual, label: "Visual", available?: visual_available?},
      %View{id: :source, label: "Source", available?: true}
    ]
  end

  defp derive_actions(%Facts{} = facts) do
    read_only? = Enum.any?(facts.issues, &match?(%Issue{id: :revision_read_only}, &1))

    [
      %Action{
        id: :compile,
        label: "Compile",
        variant: :primary,
        enabled?: not read_only? and facts.lifecycle_state != :compiled,
        disabled_reason: compile_disabled_reason(facts, read_only?)
      }
    ]
  end

  defp compile_disabled_reason(_facts, true), do: "Saved revisions are read-only."

  defp compile_disabled_reason(%Facts{lifecycle_state: :compiled}, false) do
    "The current source is already compiled."
  end

  defp compile_disabled_reason(_facts, false), do: nil

  defp derive_issues(assigns) do
    runtime_status = Map.get(assigns, :runtime_status, default_runtime_status())

    [
      model_issue(model_from_assigns(assigns)),
      compile_issue(Map.get(assigns, :sequence_draft), runtime_status),
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

  defp model_issue(%Model{recovery: :unsupported, diagnostics: diagnostics}) do
    %Issue{id: :visual_unavailable, detail: Enum.join(diagnostics, " ")}
  end

  defp model_issue(_model), do: nil

  defp compile_issue(%SequenceDraft{compile_diagnostics: [first | _]}, _runtime_status) do
    %Issue{id: :compile_failed, detail: first}
  end

  defp compile_issue(_draft, _runtime_status), do: nil

  defp stale_issue(source_digest, runtime_status, %SequenceDraft{} = draft) do
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

  defp notice_from_state(%Facts{issues: issues, lifecycle_state: lifecycle_state}) do
    case prioritize_issues(issues) do
      [issue | _] ->
        notice_from_issue(issue)

      [] when lifecycle_state == :compiled ->
        %Notice{
          tone: :good,
          title: "Compiled",
          message: "The current source compiled into a canonical sequence model."
        }

      _ ->
        nil
    end
  end

  defp prioritize_issues(issues), do: Enum.sort_by(issues, &issue_priority/1)

  defp issue_priority(%Issue{id: :compile_failed}), do: 0
  defp issue_priority(%Issue{id: :compile_blocked_old_code}), do: 1
  defp issue_priority(%Issue{id: :compile_runtime_failed}), do: 2
  defp issue_priority(%Issue{id: :compiled_stale}), do: 3
  defp issue_priority(%Issue{id: :visual_edit_failed}), do: 4
  defp issue_priority(%Issue{id: :visual_unavailable}), do: 5
  defp issue_priority(%Issue{id: :revision_read_only}), do: 6
  defp issue_priority(_issue), do: 100

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

  defp notice_from_issue(%Issue{id: :visual_unavailable, detail: message}) do
    %Notice{tone: :error, title: "Visual summary unavailable", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_edit_failed, detail: message}) do
    %Notice{tone: :error, title: "Visual edit failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :revision_read_only, detail: message}) do
    %Notice{tone: :warning, title: "Saved revision", message: message}
  end

  defp compile_error?(runtime_status, %SequenceDraft{} = draft) do
    draft.compile_diagnostics != [] or not is_nil(Map.get(runtime_status, :blocked_reason))
  end

  defp compile_error?(runtime_status, _draft) do
    not is_nil(Map.get(runtime_status, :blocked_reason))
  end

  defp normalize_view(view) when view in [:visual, :source], do: view
  defp normalize_view("visual"), do: :visual
  defp normalize_view("source"), do: :source
  defp normalize_view(_other), do: :source
end
