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

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    %Facts{
      artifact_id: Map.fetch!(assigns, :sequence_id),
      source: Map.fetch!(assigns, :draft_source),
      model: model_from_assigns(assigns),
      lifecycle_state:
        lifecycle_state(
          Map.fetch!(assigns, :current_source_digest),
          Map.get(assigns, :validated_source_digest),
          Map.get(assigns, :validation_diagnostics, [])
        ),
      desired_state:
        desired_state(
          Map.fetch!(assigns, :current_source_digest),
          Map.get(assigns, :validated_source_digest)
        ),
      observed_state:
        observed_state(
          Map.fetch!(assigns, :current_source_digest),
          Map.get(assigns, :validated_source_digest),
          Map.get(assigns, :validation_diagnostics, [])
        ),
      requested_view: normalize_view(Map.get(assigns, :requested_view, :visual)),
      issues: derive_issues(assigns)
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
      notice: notice_from_state(facts, selected_view),
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

  defp lifecycle_state(source_digest, source_digest, []), do: :validated
  defp lifecycle_state(source_digest, source_digest, [_ | _]), do: :invalid
  defp lifecycle_state(_source_digest, _validated_source_digest, _diagnostics), do: :draft

  defp desired_state(source_digest, source_digest), do: :validated
  defp desired_state(_source_digest, _validated_source_digest), do: :draft

  defp observed_state(source_digest, source_digest, []), do: :validated
  defp observed_state(source_digest, source_digest, [_ | _]), do: :invalid
  defp observed_state(_source_digest, _validated_source_digest, _diagnostics), do: :idle

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
        id: :validate,
        label: "Validate",
        variant: :primary,
        enabled?: not read_only? and facts.lifecycle_state != :validated,
        disabled_reason: validate_disabled_reason(facts, read_only?)
      }
    ]
  end

  defp validate_disabled_reason(_facts, true), do: "Saved revisions are read-only."

  defp validate_disabled_reason(%Facts{lifecycle_state: :validated}, false) do
    "The current source is already validated."
  end

  defp validate_disabled_reason(_facts, false), do: nil

  defp derive_issues(assigns) do
    [
      model_issue(model_from_assigns(assigns)),
      validation_issue(
        Map.fetch!(assigns, :current_source_digest),
        Map.get(assigns, :validated_source_digest),
        Map.get(assigns, :validation_diagnostics, [])
      ),
      manual_issue(Map.get(assigns, :sequence_issue))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp model_issue(%Model{recovery: :unsupported, diagnostics: diagnostics}) do
    %Issue{id: :visual_unavailable, detail: Enum.join(diagnostics, " ")}
  end

  defp model_issue(_model), do: nil

  defp validation_issue(source_digest, source_digest, [first | _]) do
    %Issue{id: :validate_failed, detail: first}
  end

  defp validation_issue(_source_digest, _validated_source_digest, _diagnostics), do: nil

  defp manual_issue(nil), do: nil
  defp manual_issue({id, detail}), do: %Issue{id: id, detail: detail}

  defp notice_from_state(%Facts{issues: issues, lifecycle_state: lifecycle_state}, _selected_view) do
    case prioritize_issues(issues) do
      [issue | _] ->
        notice_from_issue(issue)

      [] when lifecycle_state == :validated ->
        %Notice{
          tone: :good,
          title: "Validated",
          message: "The current source compiled into a validated canonical sequence model."
        }

      _ ->
        nil
    end
  end

  defp prioritize_issues(issues), do: Enum.sort_by(issues, &issue_priority/1)

  defp issue_priority(%Issue{id: :validate_failed}), do: 0
  defp issue_priority(%Issue{id: :visual_edit_failed}), do: 1
  defp issue_priority(%Issue{id: :visual_unavailable}), do: 1
  defp issue_priority(%Issue{id: :revision_read_only}), do: 2
  defp issue_priority(_issue), do: 100

  defp notice_from_issue(%Issue{id: :validate_failed, detail: message}) do
    %Notice{tone: :error, title: "Validation failed", message: message}
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

  defp normalize_view(view) when view in [:visual, :source], do: view
  defp normalize_view("visual"), do: :visual
  defp normalize_view("source"), do: :source
  defp normalize_view(_other), do: :source
end
