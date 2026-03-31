defmodule Ogol.Studio.MachineCell do
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
  alias Ogol.Studio.WorkspaceStore.MachineDraft

  @visual_compile_block_message "Resolve visual validation first or switch to Code."

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    source_digest = Map.fetch!(assigns, :current_source_digest)
    runtime_status = Map.get(assigns, :runtime_status, default_runtime_status())

    %Facts{
      artifact_id: Map.fetch!(assigns, :machine_id),
      source: Map.fetch!(assigns, :draft_source),
      model: model_from_assigns(assigns),
      lifecycle_state:
        lifecycle_state(source_digest, runtime_status, Map.get(assigns, :machine_draft)),
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
      actions: derive_actions(facts, selected_view),
      views: views
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

  defp model_from_assigns(assigns) do
    case Map.get(assigns, :sync_state, :synced) do
      :synced ->
        %Model{
          value: Map.get(assigns, :machine_model),
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

  defp normalize_view(view) when view in [:config, :source, :inspect], do: view
  defp normalize_view("config"), do: :config
  defp normalize_view("source"), do: :source
  defp normalize_view("code"), do: :source
  defp normalize_view("inspect"), do: :inspect
  defp normalize_view(_other), do: :config

  defp lifecycle_state(source_digest, runtime_status, %MachineDraft{} = draft) do
    Cell.source_lifecycle(
      source_digest,
      Map.get(runtime_status, :source_digest),
      compile_error?(runtime_status, draft)
    )
  end

  defp lifecycle_state(source_digest, runtime_status, _draft) do
    Cell.source_lifecycle(source_digest, Map.get(runtime_status, :source_digest), false)
  end

  defp derive_views do
    [
      %View{id: :config, label: "Config", available?: true},
      %View{id: :source, label: "Code", available?: true},
      %View{id: :inspect, label: "Inspect", available?: true}
    ]
  end

  defp derive_actions(%Facts{} = facts, selected_view) do
    compile_enabled? = compile_enabled?(facts, selected_view)

    [
      %Action{
        id: :compile,
        label: "Compile",
        variant: :primary,
        enabled?: compile_enabled? and facts.lifecycle_state != :compiled,
        disabled_reason: compile_disabled_reason(facts, selected_view)
      }
    ]
  end

  defp compile_enabled?(%Facts{} = facts, :config) when facts.model.recovery == :full do
    not Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1))
  end

  defp compile_enabled?(_facts, _selected_view), do: true

  defp compile_disabled_reason(%Facts{} = facts, :config) when facts.model.recovery == :full do
    cond do
      Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) ->
        @visual_compile_block_message

      facts.lifecycle_state == :compiled ->
        "The current source is already compiled."

      true ->
        nil
    end
  end

  defp compile_disabled_reason(%Facts{} = facts, _selected_view) do
    if facts.lifecycle_state == :compiled do
      "The current source is already compiled."
    end
  end

  defp derive_issues(assigns, runtime_status) do
    requested_view = normalize_view(Map.get(assigns, :requested_view, :config))
    model = model_from_assigns(assigns)
    current_source_digest = Map.fetch!(assigns, :current_source_digest)
    draft = Map.get(assigns, :machine_draft)

    [
      validation_issue(Map.get(assigns, :validation_errors, []), requested_view),
      model_issue(model),
      stale_issue(current_source_digest, runtime_status, draft),
      manual_issue(Map.get(assigns, :machine_issue)),
      compile_issue(draft),
      runtime_issue(runtime_status, Map.fetch!(assigns, :machine_id))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp validation_issue([], _requested_view), do: nil
  defp validation_issue([first | _], :config), do: %Issue{id: :visual_invalid, detail: first}
  defp validation_issue(_errors, _requested_view), do: nil

  defp model_issue(%Model{recovery: :unsupported, diagnostics: diagnostics}) do
    %Issue{id: :visual_unavailable, detail: List.wrap(diagnostics)}
  end

  defp model_issue(_model), do: nil

  defp stale_issue(current_source_digest, runtime_status, %MachineDraft{} = draft) do
    if not compile_error?(runtime_status, draft) and
         Cell.source_stale?(current_source_digest, Map.get(runtime_status, :source_digest)) do
      %Issue{id: :compiled_stale, detail: "The source changed after the last successful compile."}
    end
  end

  defp stale_issue(_current_source_digest, _runtime_status, _draft), do: nil

  defp manual_issue(nil), do: nil
  defp manual_issue({id, detail}), do: %Issue{id: id, detail: detail}

  defp compile_issue(%MachineDraft{build_diagnostics: [first | _]}) do
    %Issue{id: :compile_failed, detail: format_diagnostic(first)}
  end

  defp compile_issue(_draft), do: nil

  defp runtime_issue(%{blocked_reason: :old_code_in_use, lingering_pids: pids}, _machine_id) do
    %Issue{id: :compile_blocked_old_code, detail: %{count: length(List.wrap(pids))}}
  end

  defp runtime_issue(%{blocked_reason: {:module_mismatch, expected, actual}}, machine_id) do
    %Issue{
      id: :compile_module_mismatch,
      detail: %{machine_id: machine_id, expected: expected, actual: actual}
    }
  end

  defp runtime_issue(%{blocked_reason: nil}, _machine_id), do: nil

  defp runtime_issue(%{blocked_reason: reason}, _machine_id) do
    %Issue{id: :compile_runtime_failed, detail: inspect(reason)}
  end

  defp notice_from_issues(issues), do: Enum.find_value(issues, &notice_from_issue/1)

  defp notice_from_issue(%Issue{id: :compiled_stale, detail: message}) do
    %Notice{tone: :warning, title: "Compiled output is stale", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_invalid, detail: message}) do
    %Notice{tone: :warning, title: "Visual update blocked", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_unavailable}), do: nil

  defp notice_from_issue(%Issue{id: :compile_failed, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :compile_missing_module, detail: message}) do
    %Notice{tone: :error, title: "Compile failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :revision_read_only, detail: message}) do
    %Notice{tone: :warning, title: "Saved revision", message: message}
  end

  defp notice_from_issue(%Issue{
         id: :compile_blocked_old_code,
         detail: %{count: count}
       }) do
    noun = if count == 1, do: "process", else: "processes"

    %Notice{
      tone: :warning,
      title: "Compile blocked",
      message: "#{count} lingering #{noun} still use the previous module version."
    }
  end

  defp notice_from_issue(%Issue{
         id: :compile_module_mismatch,
         detail: %{machine_id: machine_id, expected: expected, actual: actual}
       }) do
    %Notice{
      tone: :error,
      title: "Compile blocked",
      message:
        "Logical id #{machine_id} is already bound to #{inspect(expected)} and cannot switch to #{inspect(actual)} in latest-only mode."
    }
  end

  defp notice_from_issue(%Issue{id: :compile_runtime_failed, detail: message}) do
    %Notice{
      tone: :error,
      title: "Compile failed",
      message: "Runtime rejected the compiled artifact: #{message}"
    }
  end

  defp compile_error?(runtime_status, %MachineDraft{} = draft) do
    draft.build_diagnostics != [] or not is_nil(Map.get(runtime_status, :blocked_reason))
  end

  defp format_diagnostic(%{file: file, position: position, message: message}),
    do: "#{file}:#{inspect(position)} #{message}"

  defp format_diagnostic(%{message: message}), do: message
  defp format_diagnostic(other) when is_binary(other), do: other
  defp format_diagnostic(other), do: inspect(other)
end
