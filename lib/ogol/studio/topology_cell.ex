defmodule Ogol.Studio.TopologyCell do
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

  @visual_start_block_message "Resolve visual validation first or switch to Source."

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    runtime_status = Map.fetch!(assigns, :runtime_status)

    %Facts{
      artifact_id: Map.fetch!(assigns, :topology_id),
      source: Map.fetch!(assigns, :draft_source),
      model: model_from_assigns(assigns),
      lifecycle_state: lifecycle_state(runtime_status),
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
      actions: derive_actions(facts, selected_view),
      views: views
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

  defp normalize_view(view) when view in [:visual, :source], do: view
  defp normalize_view("visual"), do: :visual
  defp normalize_view("source"), do: :source
  defp normalize_view(_other), do: :source

  defp lifecycle_state(%{selected_running?: true}), do: :applied
  defp lifecycle_state(_runtime_status), do: :draft

  defp desired_state(%{selected_running?: true}), do: :running
  defp desired_state(_runtime_status), do: :stopped

  defp observed_state(%{selected_running?: true}), do: :running
  defp observed_state(%{other_running?: true}), do: :degraded
  defp observed_state(_runtime_status), do: :idle

  defp derive_views(visual_available?) do
    [
      %View{id: :visual, label: "Visual", available?: visual_available?},
      %View{id: :source, label: "Source", available?: true}
    ]
  end

  defp derive_actions(%Facts{} = facts, selected_view) do
    if facts.observed_state == :running do
      [%Action{id: :stop, label: "Stop", variant: :secondary, enabled?: true}]
    else
      enabled? = start_enabled?(facts, selected_view)

      [
        %Action{
          id: :start,
          label: "Start",
          variant: :primary,
          enabled?: enabled?,
          disabled_reason: start_disabled_reason(facts, selected_view)
        }
      ]
    end
  end

  defp start_enabled?(%Facts{} = facts, :visual) do
    not Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) and
      not Enum.any?(facts.issues, &match?(%Issue{id: :other_topology_running}, &1)) and
      not Enum.any?(facts.issues, &match?(%Issue{id: :missing_module}, &1))
  end

  defp start_enabled?(%Facts{} = facts, _selected_view) do
    not Enum.any?(facts.issues, &match?(%Issue{id: :other_topology_running}, &1)) and
      not Enum.any?(facts.issues, &match?(%Issue{id: :missing_module}, &1))
  end

  defp start_disabled_reason(%Facts{} = facts, :visual) do
    cond do
      Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) ->
        @visual_start_block_message

      Enum.any?(facts.issues, &match?(%Issue{id: :other_topology_running}, &1)) ->
        "Another topology is already active."

      Enum.any?(facts.issues, &match?(%Issue{id: :missing_module}, &1)) ->
        "Source must define one topology module before it can be started."

      true ->
        nil
    end
  end

  defp start_disabled_reason(%Facts{} = facts, _selected_view) do
    cond do
      Enum.any?(facts.issues, &match?(%Issue{id: :other_topology_running}, &1)) ->
        "Another topology is already active."

      Enum.any?(facts.issues, &match?(%Issue{id: :missing_module}, &1)) ->
        "Source must define one topology module before it can be started."

      true ->
        nil
    end
  end

  defp derive_issues(assigns, runtime_status) do
    requested_view = normalize_view(Map.get(assigns, :requested_view, :source))
    model = model_from_assigns(assigns)

    [
      validation_issue(Map.get(assigns, :validation_errors, []), requested_view),
      model_issue(model),
      runtime_issue(runtime_status),
      feedback_issue(Map.get(assigns, :studio_feedback))
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

  defp runtime_issue(%{selected_running?: true, active: %{root: root}}) do
    %Issue{id: :running_selected, detail: humanize_id(Atom.to_string(root))}
  end

  defp runtime_issue(%{other_running?: true, active: %{root: root}}) do
    %Issue{id: :other_topology_running, detail: humanize_id(Atom.to_string(root))}
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
    |> prioritize_issues()
    |> case do
      [issue | _] -> notice_from_issue(issue)
      [] -> nil
    end
  end

  defp prioritize_issues(issues) do
    Enum.sort_by(issues, &issue_priority/1)
  end

  defp issue_priority(%Issue{id: :feedback}), do: 0
  defp issue_priority(%Issue{id: :visual_invalid}), do: 1
  defp issue_priority(%Issue{id: :visual_unavailable}), do: 2
  defp issue_priority(%Issue{id: :other_topology_running}), do: 3
  defp issue_priority(%Issue{id: :running_selected}), do: 4
  defp issue_priority(%Issue{id: :missing_module}), do: 5
  defp issue_priority(_issue), do: 100

  defp notice_from_issue(%Issue{id: :feedback, detail: %{tone: tone, title: title, detail: detail}}) do
    %Notice{tone: tone, title: title, message: detail}
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
      title: "Start failed",
      message: "Source must define one topology module before it can be started."
    }
  end

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
