defmodule Ogol.Hardware.Studio.Cell do
  @moduledoc false

  @behaviour Ogol.Studio.Cell

  alias Ogol.Studio.Cell
  alias Ogol.Studio.Cell.Derived
  alias Ogol.Studio.Cell.Facts
  alias Ogol.Studio.Cell.Issue
  alias Ogol.Studio.Cell.Model
  alias Ogol.Studio.Cell.Notice
  alias Ogol.Studio.Cell.View
  alias Ogol.Session.Workspace.SourceDraft

  @visual_compile_block_message "Resolve the EtherCAT form issues first or switch to Source."

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    runtime_status = Map.get(assigns, :runtime_status, default_runtime_status())

    %Facts{
      artifact_id: Map.get(assigns, :adapter_id),
      source: Map.fetch!(assigns, :hardware_source),
      model: model_from_assigns(assigns),
      lifecycle_state:
        lifecycle_state(
          Map.fetch!(assigns, :current_source_digest),
          runtime_status,
          Map.get(assigns, :hardware_draft)
        ),
      desired_state: nil,
      observed_state: nil,
      requested_view: normalize_view(Map.get(assigns, :requested_view, :config)),
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
      controls: derive_controls(facts, selected_view),
      views: views
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

  defp model_from_assigns(assigns) do
    case Map.get(assigns, :sync_state, :synced) do
      :synced ->
        %Model{
          value: Map.get(assigns, :hardware),
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

  defp derive_controls(%Facts{} = facts, selected_view) do
    [
      Cell.module_compile_control(
        :hardware,
        facts,
        variant: :primary,
        enabled?: compile_enabled?(facts, selected_view),
        disabled_reason: compile_disabled_reason(facts, selected_view)
      )
    ]
  end

  defp compile_enabled?(%Facts{} = facts, selected_view) when selected_view == :config do
    not Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1))
  end

  defp compile_enabled?(_facts, _selected_view), do: true

  defp compile_disabled_reason(%Facts{} = facts, selected_view) when selected_view == :config do
    cond do
      Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) ->
        @visual_compile_block_message

      true ->
        nil
    end
  end

  defp compile_disabled_reason(%Facts{} = _facts, _selected_view), do: nil

  defp derive_issues(assigns, runtime_status) do
    requested_view = normalize_view(Map.get(assigns, :requested_view, :config))
    model = model_from_assigns(assigns)
    current_source_digest = Map.fetch!(assigns, :current_source_digest)
    draft = Map.get(assigns, :hardware_draft)

    [
      validation_issue(Map.get(assigns, :validation_errors, []), requested_view),
      model_issue(model),
      stale_issue(current_source_digest, runtime_status, draft),
      manual_issue(Map.get(assigns, :hardware_issue)),
      compile_issue(draft),
      runtime_issue(runtime_status)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp validation_issue([], _requested_view), do: nil

  defp validation_issue([first | _], requested_view) when requested_view == :config do
    %Issue{id: :visual_invalid, detail: first}
  end

  defp validation_issue(_errors, _requested_view), do: nil

  defp model_issue(%Model{recovery: :unsupported, diagnostics: diagnostics}) do
    %Issue{id: :visual_unavailable, detail: Enum.join(List.wrap(diagnostics), " ")}
  end

  defp model_issue(_model), do: nil

  defp stale_issue(current_source_digest, runtime_status, %SourceDraft{} = draft) do
    if not compile_error?(runtime_status, draft) and
         Cell.source_stale?(current_source_digest, Map.get(runtime_status, :source_digest)) do
      %Issue{id: :compiled_stale, detail: "The source changed after the last successful compile."}
    end
  end

  defp stale_issue(_current_source_digest, _runtime_status, _draft), do: nil

  defp manual_issue(nil), do: nil
  defp manual_issue({id, detail}), do: %Issue{id: id, detail: detail}

  defp compile_issue(%{diagnostics: [first | _]}) do
    %Issue{id: :compile_failed, detail: first}
  end

  defp compile_issue(_runtime_status), do: nil

  defp runtime_issue(%{blocked_reason: :old_code_in_use, lingering_pids: pids}) do
    %Issue{id: :compile_blocked_old_code, detail: %{count: length(List.wrap(pids))}}
  end

  defp runtime_issue(%{blocked_reason: reason}) when not is_nil(reason) do
    %Issue{id: :compile_runtime_failed, detail: inspect(reason)}
  end

  defp runtime_issue(_runtime_status), do: nil

  defp notice_from_issues(issues), do: Enum.find_value(issues, &notice_from_issue/1)

  defp notice_from_issue(%Issue{id: :compiled_stale, detail: message}) do
    %Notice{tone: :warning, title: "Compiled output is stale", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_invalid, detail: message}) do
    %Notice{tone: :warning, title: "Visual update blocked", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_unavailable, detail: message}) do
    %Notice{tone: :error, title: "Visual editor unavailable", message: message}
  end

  defp notice_from_issue(%Issue{id: :compile_failed, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :compile_missing_module, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :compile_runtime_failed, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :compile_blocked_old_code, detail: %{count: count}}) do
    noun = if count == 1, do: "process", else: "processes"

    %Notice{
      tone: :warning,
      title: "Compile blocked",
      message: "#{count} lingering #{noun} still use the previous module version."
    }
  end

  defp notice_from_issue(_issue), do: nil

  defp compile_error?(runtime_status, _draft) do
    Map.get(runtime_status, :diagnostics, []) != [] or
      not is_nil(Map.get(runtime_status, :blocked_reason))
  end
end
