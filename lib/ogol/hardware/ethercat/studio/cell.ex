defmodule Ogol.Hardware.EtherCAT.Studio.Cell do
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

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    source = Map.get(assigns, :driver_source, "")
    runtime_status = Map.get(assigns, :driver_runtime_status, default_runtime_status())

    %Facts{
      artifact_id: Map.get(assigns, :selected_driver_module_name),
      source: source,
      model: model_from_assigns(assigns),
      lifecycle_state:
        Cell.source_lifecycle(
          Map.get(assigns, :driver_source_digest, ""),
          Map.get(runtime_status, :source_digest),
          Map.get(runtime_status, :diagnostics, [])
        ),
      desired_state: nil,
      observed_state: nil,
      requested_view: normalize_view(Map.get(assigns, :driver_requested_view, :config)),
      issues: derive_issues(assigns, runtime_status)
    }
  end

  @impl true
  @spec derive(Facts.t()) :: Derived.t()
  def derive(%Facts{} = facts) do
    {selected_view, views} = Cell.resolve_views(facts.requested_view, derive_views())

    %Derived{
      selected_view: selected_view,
      notice: notice_from_issues(facts.issues),
      controls: derive_controls(facts),
      views: views
    }
  end

  @spec default_runtime_status() :: map()
  def default_runtime_status do
    %{
      source_digest: nil,
      diagnostics: []
    }
  end

  defp model_from_assigns(assigns) do
    case Map.get(assigns, :selected_driver_entry) do
      nil ->
        %Model{
          value: nil,
          recovery: :unavailable,
          diagnostics: []
        }

      entry ->
        %Model{
          value: driver_metadata(entry),
          recovery: :full,
          diagnostics: []
        }
    end
  end

  defp normalize_view(view) when view in [:config, :source], do: view
  defp normalize_view("config"), do: :config
  defp normalize_view("source"), do: :source
  defp normalize_view(_other), do: :config

  defp derive_views do
    [
      %View{id: :config, label: "Config", available?: true},
      %View{id: :source, label: "Source", available?: true}
    ]
  end

  defp derive_controls(%Facts{} = facts) do
    [
      %Control{
        id: compile_control_id(facts.lifecycle_state),
        label: compile_control_label(facts.lifecycle_state),
        variant: :primary,
        enabled?: compile_enabled?(facts),
        disabled_reason: compile_disabled_reason(facts),
        operation: nil
      }
    ]
  end

  defp compile_control_id(lifecycle_state) when lifecycle_state in [:compiled, :stale],
    do: :recompile

  defp compile_control_id(_lifecycle_state), do: :compile

  defp compile_control_label(lifecycle_state) when lifecycle_state in [:compiled, :stale],
    do: "Recompile"

  defp compile_control_label(_lifecycle_state), do: "Compile"

  defp compile_enabled?(%Facts{artifact_id: artifact_id, source: source}) do
    is_binary(artifact_id) and artifact_id != "" and is_binary(source) and source != ""
  end

  defp compile_disabled_reason(%Facts{} = facts) do
    cond do
      is_nil(facts.model.value) ->
        "Select a driver first."

      not compile_enabled?(facts) ->
        "Driver source is unavailable."

      true ->
        nil
    end
  end

  defp derive_issues(assigns, runtime_status) do
    [
      compile_issue(Map.get(runtime_status, :diagnostics, [])),
      source_issue(Map.get(assigns, :driver_source_error)),
      selection_issue(Map.get(assigns, :selected_driver_entry))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp compile_issue([first | _]), do: %Issue{id: :compile_failed, detail: first}
  defp compile_issue(_diagnostics), do: nil

  defp source_issue(nil), do: nil
  defp source_issue(message), do: %Issue{id: :source_unavailable, detail: message}

  defp selection_issue(nil), do: %Issue{id: :selection_required, detail: "Select a driver first."}
  defp selection_issue(_entry), do: nil

  defp notice_from_issues(issues), do: Enum.find_value(issues, &notice_from_issue/1)

  defp notice_from_issue(%Issue{id: :compile_failed, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :source_unavailable, detail: message}) do
    %Notice{tone: :error, title: "Driver source unavailable", message: message}
  end

  defp notice_from_issue(%Issue{id: :selection_required, detail: message}) do
    %Notice{tone: :warning, title: "No driver selected", message: message}
  end

  defp notice_from_issue(_issue), do: nil

  defp driver_metadata(entry) when is_map(entry) do
    %{
      id: Map.get(entry, :id),
      label: Map.get(entry, :label),
      name: Map.get(entry, :name),
      driver: Map.get(entry, :module_name),
      source_path: Map.get(entry, :source_path)
    }
  end
end
