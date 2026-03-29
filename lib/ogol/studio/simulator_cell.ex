defmodule Ogol.Studio.SimulatorCell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.Studio.Cell.Action
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.Issue
  alias Ogol.Studio.Cell.Model
  alias Ogol.Studio.Cell.Notice
  alias Ogol.Studio.Cell.View

  @write_blocked_message "Simulator writes are blocked by the current hardware mode."

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    hardware_context = Map.fetch!(assigns, :hardware_context)
    running? = running?(hardware_context)

    %Facts{
      artifact_id: Map.fetch!(assigns, :simulation_config_id),
      source: Map.fetch!(assigns, :simulation_source),
      model: %Model{
        value:
          Map.get(assigns, :effective_simulation_config) ||
            Map.get(assigns, :simulation_config_form),
        recovery: :full,
        diagnostics: []
      },
      lifecycle_state: lifecycle_state(running?),
      desired_state: desired_state(running?),
      observed_state: observed_state(running?),
      requested_view: normalize_view(Map.get(assigns, :requested_view, :visual)),
      issues: derive_issues(assigns, hardware_context)
    }
  end

  @impl true
  @spec derive(Facts.t()) :: Derived.t()
  def derive(%Facts{} = facts) do
    %Derived{
      selected_view: facts.requested_view,
      notice: notice_from_issues(facts.issues),
      actions: derive_actions(facts),
      views: derive_views()
    }
  end

  @spec simulation_allowed?(map()) :: boolean()
  def simulation_allowed?(hardware_context) when is_map(hardware_context) do
    hardware_context.mode.kind == :testing and
      hardware_context.mode.write_policy == :enabled and
      hardware_context.observed.source in [:none, :simulator]
  end

  defp lifecycle_state(true), do: :running
  defp lifecycle_state(false), do: :draft

  defp desired_state(true), do: :running
  defp desired_state(false), do: :stopped

  defp observed_state(true), do: :running
  defp observed_state(false), do: :idle

  defp normalize_view(:visual), do: :visual
  defp normalize_view(:source), do: :source
  defp normalize_view("visual"), do: :visual
  defp normalize_view("source"), do: :source
  defp normalize_view(_other), do: :visual

  defp derive_views do
    [
      %View{id: :visual, label: "Visual", available?: true},
      %View{id: :source, label: "Source", available?: true}
    ]
  end

  defp derive_actions(%Facts{} = facts) do
    enabled? = not Enum.any?(facts.issues, &match?(%Issue{id: :write_blocked}, &1))
    disabled_reason = if(enabled?, do: nil, else: @write_blocked_message)

    case facts.observed_state do
      :running ->
        [
          %Action{
            id: :stop_simulation,
            label: "Stop simulation",
            variant: :secondary,
            enabled?: enabled?,
            disabled_reason: disabled_reason
          }
        ]

      _other ->
        [
          %Action{
            id: :start_simulation,
            label: "Start simulation",
            variant: :primary,
            enabled?: enabled?,
            disabled_reason: disabled_reason
          }
        ]
    end
  end

  defp derive_issues(assigns, hardware_context) do
    [
      feedback_issue(Map.get(assigns, :hardware_feedback)),
      write_policy_issue(hardware_context)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp feedback_issue(%{status: status, summary: summary, detail: detail})
       when is_binary(summary) and status in [:ok, :pending] do
    %Issue{id: :feedback_info, detail: %{summary: summary, detail: detail}}
  end

  defp feedback_issue(%{summary: summary, detail: detail}) when is_binary(summary) do
    %Issue{id: :feedback_error, detail: %{summary: summary, detail: detail}}
  end

  defp feedback_issue(_feedback), do: nil

  defp write_policy_issue(hardware_context) do
    if simulation_allowed?(hardware_context) do
      nil
    else
      %Issue{
        id: :write_blocked,
        detail:
          "write_policy=#{hardware_context.mode.write_policy} authority=#{hardware_context.mode.authority_scope}"
      }
    end
  end

  defp notice_from_issues(issues) do
    issues
    |> Enum.sort_by(&issue_priority/1)
    |> case do
      [issue | _] -> notice_from_issue(issue)
      [] -> nil
    end
  end

  defp issue_priority(%Issue{id: :feedback_error}), do: 0
  defp issue_priority(%Issue{id: :feedback_info}), do: 1
  defp issue_priority(%Issue{id: :write_blocked}), do: 2
  defp issue_priority(_issue), do: 100

  defp notice_from_issue(%Issue{id: :feedback_info, detail: %{summary: summary, detail: detail}}) do
    %Notice{tone: :info, title: summary, message: detail}
  end

  defp notice_from_issue(%Issue{id: :feedback_error, detail: %{summary: summary, detail: detail}}) do
    %Notice{tone: :error, title: summary, message: detail}
  end

  defp notice_from_issue(%Issue{id: :write_blocked, detail: detail}) do
    %Notice{tone: :warning, title: "Simulation writes are blocked", message: detail}
  end

  defp running?(%{observed: %{source: :simulator}}), do: true
  defp running?(_hardware_context), do: false
end
