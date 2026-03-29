defmodule Ogol.Studio.EthercatMasterCell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.Studio.Cell.Action
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.Issue
  alias Ogol.Studio.Cell.Model
  alias Ogol.Studio.Cell.Notice
  alias Ogol.Studio.Cell.View

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    master_running? = master_running?(Map.fetch!(assigns, :ethercat))

    %Facts{
      artifact_id: "ethercat_master",
      source: Map.fetch!(assigns, :master_cell_source),
      model: %Model{
        value: Map.fetch!(assigns, :simulation_config_form),
        recovery: :full,
        diagnostics: []
      },
      lifecycle_state: lifecycle_state(master_running?),
      desired_state: desired_state(master_running?),
      observed_state: observed_state(master_running?),
      requested_view:
        normalize_requested_view(Map.get(assigns, :requested_master_view), master_running?),
      issues: derive_issues(assigns, master_running?)
    }
  end

  @impl true
  @spec derive(Facts.t()) :: Derived.t()
  def derive(%Facts{} = facts) do
    runtime_available? = facts.observed_state == :running

    %Derived{
      selected_view: facts.requested_view,
      notice: notice_from_issues(facts.issues),
      actions: derive_actions(runtime_available?),
      views: derive_views(runtime_available?)
    }
  end

  defp lifecycle_state(true), do: :applied
  defp lifecycle_state(false), do: :draft

  defp desired_state(true), do: :running
  defp desired_state(false), do: :stopped

  defp observed_state(true), do: :running
  defp observed_state(false), do: :idle

  defp normalize_requested_view(view, master_running?) do
    case view do
      :visual -> :visual
      :source -> :source
      :runtime when master_running? -> :runtime
      "visual" -> :visual
      "source" -> :source
      "runtime" when master_running? -> :runtime
      _other -> :visual
    end
  end

  defp derive_views(runtime_available?) do
    [
      %View{id: :visual, label: "Visual", available?: true},
      %View{id: :runtime, label: "Runtime", available?: runtime_available?},
      %View{id: :source, label: "Source", available?: true}
    ]
  end

  defp derive_actions(true) do
    [
      %Action{id: :stop_master, label: "Stop master", variant: :secondary, enabled?: true}
    ]
  end

  defp derive_actions(false) do
    [
      %Action{id: :scan_master, label: "Scan", variant: :secondary, enabled?: true},
      %Action{id: :start_master, label: "Start master", variant: :primary, enabled?: true}
    ]
  end

  defp derive_issues(assigns, master_running?) do
    [
      feedback_issue(Map.get(assigns, :hardware_feedback)),
      steady_state_issue(Map.fetch!(assigns, :hardware_context), master_running?)
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

  defp steady_state_issue(_hardware_context, true) do
    %Issue{
      id: :master_running,
      detail:
        "Edits in the visual form update the draft only. Stop and restart the master when you want the running runtime to follow the new draft."
    }
  end

  defp steady_state_issue(%{observed: %{source: :simulator}}, false) do
    %Issue{
      id: :simulator_backend_running,
      detail:
        "The simulated EtherCAT ring is available. Start the master to attach to it and scan watched slaves."
    }
  end

  defp steady_state_issue(%{observed: %{source: :none}}, false) do
    %Issue{
      id: :master_idle,
      detail:
        "Start the master against a running simulator or current EtherCAT backend, then scan to sync domains and watched slaves."
    }
  end

  defp steady_state_issue(_hardware_context, false), do: nil

  defp notice_from_issues([issue | _]), do: notice_from_issue(issue)
  defp notice_from_issues([]), do: nil

  defp notice_from_issue(%Issue{id: :feedback_info, detail: %{summary: summary, detail: detail}}) do
    %Notice{tone: :info, title: summary, message: detail}
  end

  defp notice_from_issue(%Issue{id: :feedback_error, detail: %{summary: summary, detail: detail}}) do
    %Notice{tone: :error, title: summary, message: detail}
  end

  defp notice_from_issue(%Issue{id: :master_running, detail: detail}) do
    %Notice{tone: :info, title: "Master runtime is active", message: detail}
  end

  defp notice_from_issue(%Issue{id: :simulator_backend_running, detail: detail}) do
    %Notice{tone: :info, title: "Simulator backend is still running", message: detail}
  end

  defp notice_from_issue(%Issue{id: :master_idle, detail: detail}) do
    %Notice{tone: :info, title: "No active master runtime", message: detail}
  end

  defp master_running?(ethercat) when is_map(ethercat) do
    case Map.get(ethercat, :master_status) do
      %{lifecycle: lifecycle} when lifecycle not in [:stopped, :idle] ->
        true

      _other ->
        case Map.get(ethercat, :state) do
          {:ok, state} when state not in [nil, :idle] -> true
          state when is_atom(state) and state not in [nil, :idle] -> true
          _other -> false
        end
    end
  end
end
