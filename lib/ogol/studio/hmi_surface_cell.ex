defmodule Ogol.Studio.HmiSurfaceCell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.HMI.SurfaceCompiler.Analysis
  alias Ogol.Studio.Cell
  alias Ogol.Studio.Cell.Action
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.Issue
  alias Ogol.Studio.Cell.Model
  alias Ogol.Studio.Cell.Notice
  alias Ogol.Studio.Cell.View

  @compile_block_message "Resolve source diagnostics before compiling this surface."

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    draft = Map.fetch!(assigns, :surface_draft)
    analysis = Map.fetch!(assigns, :source_analysis)
    current_assignment = Map.fetch!(assigns, :current_assignment)
    cell = Map.fetch!(assigns, :cell)

    %Facts{
      artifact_id: to_string(cell.surface_id),
      source: Map.fetch!(assigns, :draft_source),
      model: model_from_analysis(analysis),
      lifecycle_state: lifecycle_state(draft, current_assignment, cell.surface_id),
      desired_state: desired_state(draft, current_assignment, cell.surface_id),
      observed_state: observed_state(draft, current_assignment, cell.surface_id),
      requested_view:
        normalize_view(Map.get(assigns, :requested_view, default_requested_view(analysis))),
      issues: derive_issues(assigns, analysis, draft, current_assignment, cell.surface_id)
    }
  end

  @impl true
  @spec derive(Facts.t()) :: Derived.t()
  def derive(%Facts{} = facts) do
    visual_available? = facts.model.recovery == :full

    {selected_view, views} =
      Cell.resolve_views(facts.requested_view, derive_views(visual_available?))

    %Derived{
      selected_view: selected_view,
      notice: notice_from_issues(facts.issues),
      actions: derive_actions(facts),
      views: views
    }
  end

  @spec default_requested_view(Analysis.t()) :: atom()
  def default_requested_view(%Analysis{classification: :visual}), do: :visual
  def default_requested_view(_analysis), do: :source

  defp model_from_analysis(%Analysis{classification: :visual} = analysis) do
    %Model{value: analysis.definition, recovery: :full, diagnostics: analysis.diagnostics}
  end

  defp model_from_analysis(%Analysis{classification: :dsl_only} = analysis) do
    %Model{value: nil, recovery: :unsupported, diagnostics: analysis.diagnostics}
  end

  defp model_from_analysis(%Analysis{} = analysis) do
    %Model{value: nil, recovery: :unavailable, diagnostics: analysis.diagnostics}
  end

  defp lifecycle_state(draft, current_assignment, surface_id) do
    cond do
      assigned?(current_assignment, surface_id) -> :assigned
      draft.deployed_version -> :deployed
      draft.compiled_version -> :compiled
      true -> :draft
    end
  end

  defp desired_state(draft, current_assignment, surface_id) do
    cond do
      assigned?(current_assignment, surface_id) -> :assigned
      draft.deployed_version -> :deployed
      draft.compiled_version -> :compiled
      true -> :draft
    end
  end

  defp observed_state(draft, current_assignment, surface_id) do
    cond do
      assigned?(current_assignment, surface_id) -> :assigned
      draft.deployed_version -> :deployed
      draft.compiled_version -> :compiled
      true -> :idle
    end
  end

  defp normalize_view(:visual), do: :visual
  defp normalize_view(:source), do: :source
  defp normalize_view("visual"), do: :visual
  defp normalize_view("source"), do: :source
  defp normalize_view(_other), do: :source

  defp derive_views(visual_available?) do
    [
      %View{id: :visual, label: "Visual", available?: visual_available?},
      %View{id: :source, label: "Source", available?: true}
    ]
  end

  defp derive_actions(%Facts{} = facts) do
    compile_enabled? = not Enum.any?(facts.issues, &match?(%Issue{id: :compile_blocked}, &1))

    compile_action = %Action{
      id: :compile,
      label: "Compile",
      variant: :secondary,
      enabled?: compile_enabled?,
      disabled_reason: if(compile_enabled?, do: nil, else: @compile_block_message)
    }

    case facts.lifecycle_state do
      :assigned ->
        [
          compile_action,
          %Action{id: :deploy, label: "Deploy", variant: :secondary, enabled?: true},
          %Action{id: :assign_panel, label: "Assign Panel", variant: :primary, enabled?: true}
        ]

      :deployed ->
        [
          compile_action,
          %Action{id: :deploy, label: "Deploy", variant: :secondary, enabled?: true},
          %Action{id: :assign_panel, label: "Assign Panel", variant: :primary, enabled?: true}
        ]

      :compiled ->
        [
          compile_action,
          %Action{id: :deploy, label: "Deploy", variant: :primary, enabled?: true}
        ]

      _other ->
        [compile_action]
    end
  end

  defp derive_issues(assigns, analysis, draft, current_assignment, surface_id) do
    [
      feedback_issue(Map.get(assigns, :studio_feedback)),
      compile_issue(analysis),
      assignment_issue(current_assignment, draft, surface_id),
      deploy_issue(draft),
      compiled_issue(draft)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp feedback_issue(%{level: level, title: title, detail: detail}) do
    %Issue{id: :feedback, detail: %{tone: tone_from_level(level), title: title, detail: detail}}
  end

  defp feedback_issue(_feedback), do: nil

  defp compile_issue(%Analysis{classification: :invalid, diagnostics: [first | _]}) do
    %Issue{id: :compile_blocked, detail: %{kind: :invalid, message: first}}
  end

  defp compile_issue(%Analysis{classification: :dsl_only, diagnostics: [first | _]}) do
    %Issue{id: :compile_blocked, detail: %{kind: :dsl_only, message: first}}
  end

  defp compile_issue(%Analysis{}), do: nil

  defp assignment_issue(current_assignment, draft, surface_id) do
    if assigned?(current_assignment, surface_id) do
      %Issue{
        id: :assigned,
        detail: %{
          panel_id: current_assignment.panel_id,
          version: current_assignment.surface_version || draft.deployed_version || "draft",
          viewport_profile: current_assignment.viewport_profile
        }
      }
    end
  end

  defp deploy_issue(%{deployed_version: version}) when is_binary(version) do
    %Issue{id: :deployed, detail: version}
  end

  defp deploy_issue(_draft), do: nil

  defp compiled_issue(%{compiled_version: version}) when is_binary(version) do
    %Issue{id: :compiled, detail: version}
  end

  defp compiled_issue(_draft), do: nil

  defp notice_from_issues(issues) do
    issues
    |> Enum.sort_by(&issue_priority/1)
    |> case do
      [issue | _] -> notice_from_issue(issue)
      [] -> nil
    end
  end

  defp issue_priority(%Issue{id: :feedback}), do: 0
  defp issue_priority(%Issue{id: :compile_blocked, detail: %{kind: :invalid}}), do: 1
  defp issue_priority(%Issue{id: :compile_blocked, detail: %{kind: :dsl_only}}), do: 2
  defp issue_priority(%Issue{id: :assigned}), do: 3
  defp issue_priority(%Issue{id: :deployed}), do: 4
  defp issue_priority(%Issue{id: :compiled}), do: 5
  defp issue_priority(_issue), do: 100

  defp notice_from_issue(%Issue{
         id: :feedback,
         detail: %{tone: tone, title: title, detail: detail}
       }) do
    %Notice{tone: tone, title: title, message: detail}
  end

  defp notice_from_issue(%Issue{
         id: :compile_blocked,
         detail: %{kind: :invalid, message: message}
       }) do
    %Notice{tone: :error, title: "Source invalid", message: message}
  end

  defp notice_from_issue(%Issue{
         id: :compile_blocked,
         detail: %{kind: :dsl_only, message: message}
       }) do
    %Notice{tone: :warning, title: "Source-only mode", message: message}
  end

  defp notice_from_issue(%Issue{
         id: :assigned,
         detail: %{panel_id: panel_id, version: version, viewport_profile: viewport_profile}
       }) do
    %Notice{
      tone: :info,
      title: "Assigned to #{panel_id}",
      message: "#{version} on #{viewport_profile}"
    }
  end

  defp notice_from_issue(%Issue{id: :deployed, detail: version}) do
    %Notice{
      tone: :info,
      title: "Deployed",
      message: "#{version} is published and ready to assign."
    }
  end

  defp notice_from_issue(%Issue{id: :compiled, detail: version}) do
    %Notice{tone: :info, title: "Compiled", message: "#{version} is ready to deploy."}
  end

  defp assigned?(current_assignment, surface_id) do
    to_string(Map.get(current_assignment, :surface_id)) == to_string(surface_id)
  end

  defp tone_from_level(:error), do: :error
  defp tone_from_level(:danger), do: :error
  defp tone_from_level(:warning), do: :warning
  defp tone_from_level(:warn), do: :warning
  defp tone_from_level(_other), do: :info
end
