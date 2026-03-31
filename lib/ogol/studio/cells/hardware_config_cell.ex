defmodule Ogol.Studio.HardwareConfigCell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.Issue
  alias Ogol.Studio.Cell.Model
  alias Ogol.Studio.Cell.Notice
  alias Ogol.Studio.Cell.View
  alias Ogol.Studio.WorkspaceStore

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    %Facts{
      artifact_id: hardware_config_id(assigns),
      source: Map.fetch!(assigns, :hardware_config_source),
      model: %Model{
        value:
          Map.get(assigns, :effective_simulation_config) ||
            Map.get(assigns, :simulation_config_form),
        recovery: model_recovery(assigns),
        diagnostics: []
      },
      lifecycle_state: nil,
      desired_state: nil,
      observed_state: nil,
      requested_view: normalize_view(Map.get(assigns, :requested_config_view, :visual)),
      issues: derive_issues(assigns)
    }
  end

  @impl true
  @spec derive(Facts.t()) :: Derived.t()
  def derive(%Facts{} = facts) do
    %Derived{
      selected_view: facts.requested_view,
      notice: notice_from_issues(facts.issues),
      actions: [],
      views: derive_views()
    }
  end

  defp hardware_config_id(assigns) do
    _ = assigns
    WorkspaceStore.hardware_config_entry_id()
  end

  defp model_recovery(assigns) do
    case Map.get(assigns, :hardware_config_error) do
      nil -> :full
      _reason -> :partial
    end
  end

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

  defp derive_issues(assigns) do
    case Map.get(assigns, :hardware_config_error) do
      nil -> []
      reason -> [%Issue{id: :config_invalid, detail: inspect(reason)}]
    end
  end

  defp notice_from_issues([issue | _]), do: notice_from_issue(issue)
  defp notice_from_issues([]), do: nil

  defp notice_from_issue(%Issue{id: :config_invalid, detail: detail}) do
    %Notice{
      tone: :warning,
      title: "Hardware config preview is invalid",
      message: detail
    }
  end
end
