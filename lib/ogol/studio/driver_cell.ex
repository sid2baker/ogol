defmodule Ogol.Studio.DriverCell do
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
  alias Ogol.Studio.DriverDraftStore.Draft

  @visual_build_block_message "Resolve visual validation first or switch to Source."

  @spec facts_from_assigns(map()) :: Facts.t()
  def facts_from_assigns(assigns) when is_map(assigns) do
    source_digest = Map.fetch!(assigns, :current_source_digest)
    runtime_status = Map.get(assigns, :runtime_status, default_runtime_status())

    %Facts{
      artifact_id: Map.fetch!(assigns, :driver_id),
      source: Map.fetch!(assigns, :draft_source),
      model: model_from_assigns(assigns),
      lifecycle_state:
        lifecycle_state(source_digest, runtime_status, Map.get(assigns, :driver_draft)),
      desired_state: desired_state(source_digest, runtime_status),
      observed_state: observed_state(source_digest, runtime_status),
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

  @spec default_runtime_status() :: map()
  def default_runtime_status do
    %{
      module: nil,
      apply_state: :draft,
      source_digest: nil,
      built_source_digest: nil,
      old_code: false,
      blocked_reason: nil,
      lingering_pids: [],
      last_build_at: nil,
      last_apply_at: nil
    }
  end

  defp model_from_assigns(assigns) do
    case Map.get(assigns, :sync_state, :synced) do
      :synced ->
        %Model{
          value: Map.get(assigns, :driver_model),
          recovery: :full,
          diagnostics: []
        }

      :partial ->
        %Model{
          value: Map.get(assigns, :driver_model),
          recovery: :partial,
          diagnostics: Enum.map(Map.get(assigns, :sync_diagnostics, []), &format_diagnostic/1)
        }

      :unsupported ->
        %Model{
          value: nil,
          recovery: :unsupported,
          diagnostics: Enum.map(Map.get(assigns, :sync_diagnostics, []), &format_diagnostic/1)
        }
    end
  end

  defp normalize_view(view) when view in [:visual, :source], do: view
  defp normalize_view("visual"), do: :visual
  defp normalize_view("source"), do: :source
  defp normalize_view(_other), do: :source

  defp lifecycle_state(source_digest, %{source_digest: source_digest}, _draft), do: :applied

  defp lifecycle_state(source_digest, %{built_source_digest: source_digest}, _draft),
    do: :built

  defp lifecycle_state(_source_digest, %{}, %Draft{
         build_artifact: nil,
         build_diagnostics: [_ | _]
       }),
       do: :invalid

  defp lifecycle_state(_source_digest, _runtime_status, _draft), do: :draft

  defp desired_state(source_digest, %{source_digest: source_digest}), do: :applied
  defp desired_state(_source_digest, _runtime_status), do: :draft

  defp observed_state(source_digest, %{source_digest: source_digest}), do: :applied
  defp observed_state(_source_digest, _runtime_status), do: :idle

  defp derive_views(visual_available?) do
    [
      %View{id: :visual, label: "Visual", available?: visual_available?},
      %View{id: :source, label: "Source", available?: true}
    ]
  end

  defp derive_actions(%Facts{} = facts, selected_view) do
    build_enabled? = build_enabled?(facts, selected_view)

    build_action = %Action{
      id: :build,
      label: "Build",
      variant: :secondary,
      enabled?: build_enabled? and facts.lifecycle_state not in [:built, :applied],
      disabled_reason: build_disabled_reason(facts, selected_view)
    }

    if facts.lifecycle_state == :built do
      [
        build_action,
        %Action{
          id: :apply,
          label: "Apply",
          variant: :primary,
          enabled?: build_enabled?,
          disabled_reason: if(build_enabled?, do: nil, else: @visual_build_block_message)
        }
      ]
    else
      [build_action]
    end
  end

  defp build_enabled?(%Facts{} = facts, :visual) do
    not Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1))
  end

  defp build_enabled?(_facts, _selected_view), do: true

  defp build_disabled_reason(%Facts{} = facts, :visual) do
    cond do
      Enum.any?(facts.issues, &match?(%Issue{id: :visual_invalid}, &1)) ->
        @visual_build_block_message

      facts.lifecycle_state in [:built, :applied] ->
        "The current source is already built."

      true ->
        nil
    end
  end

  defp build_disabled_reason(%Facts{} = facts, _selected_view) do
    if facts.lifecycle_state in [:built, :applied] do
      "The current source is already built."
    end
  end

  defp derive_issues(assigns, runtime_status) do
    requested_view = normalize_view(Map.get(assigns, :requested_view, :source))
    model = model_from_assigns(assigns)

    [
      validation_issue(Map.get(assigns, :validation_errors, []), requested_view),
      model_issue(model),
      manual_issue(Map.get(assigns, :driver_issue)),
      build_issue(Map.get(assigns, :driver_draft)),
      runtime_issue(runtime_status, Map.fetch!(assigns, :driver_id))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp validation_issue([], _requested_view), do: nil

  defp validation_issue([first | _], :visual) do
    %Issue{id: :visual_invalid, detail: format_error(first)}
  end

  defp validation_issue(_errors, _requested_view), do: nil

  defp model_issue(%Model{recovery: :partial, diagnostics: diagnostics}) do
    %Issue{id: :partial_recovery, detail: Enum.join(diagnostics, " ")}
  end

  defp model_issue(%Model{recovery: :unsupported, diagnostics: diagnostics}) do
    %Issue{id: :visual_unavailable, detail: Enum.join(diagnostics, " ")}
  end

  defp model_issue(_model), do: nil

  defp manual_issue(nil), do: nil
  defp manual_issue({id, detail}), do: %Issue{id: id, detail: detail}

  defp build_issue(%Draft{build_artifact: nil, build_diagnostics: [first | _]}) do
    %Issue{id: :build_failed, detail: format_diagnostic(first)}
  end

  defp build_issue(_draft), do: nil

  defp runtime_issue(%{blocked_reason: :old_code_in_use, lingering_pids: pids}, _driver_id) do
    %Issue{id: :apply_blocked_old_code, detail: %{count: length(List.wrap(pids))}}
  end

  defp runtime_issue(%{blocked_reason: {:module_mismatch, expected, actual}}, driver_id) do
    %Issue{
      id: :apply_module_mismatch,
      detail: %{driver_id: driver_id, expected: expected, actual: actual}
    }
  end

  defp runtime_issue(%{blocked_reason: nil}, _driver_id), do: nil

  defp runtime_issue(%{blocked_reason: reason}, _driver_id) do
    %Issue{id: :apply_failed, detail: inspect(reason)}
  end

  defp notice_from_issues([issue | _]), do: notice_from_issue(issue)
  defp notice_from_issues([]), do: nil

  defp notice_from_issue(%Issue{id: :visual_invalid, detail: message}) do
    %Notice{tone: :warning, title: "Visual update blocked", message: message}
  end

  defp notice_from_issue(%Issue{id: :visual_unavailable, detail: message}) do
    %Notice{tone: :error, title: "Visual editor unavailable", message: message}
  end

  defp notice_from_issue(%Issue{id: :partial_recovery, detail: message}) do
    %Notice{tone: :warning, title: "Partial visual recovery", message: message}
  end

  defp notice_from_issue(%Issue{id: :build_failed, detail: message}) do
    %Notice{tone: :error, title: "Build failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :build_missing_module, detail: message}) do
    %Notice{tone: :error, title: "Build failed", message: message}
  end

  defp notice_from_issue(%Issue{id: :revision_read_only, detail: message}) do
    %Notice{tone: :warning, title: "Saved revision", message: message}
  end

  defp notice_from_issue(%Issue{id: :apply_without_build, detail: message}) do
    %Notice{tone: :error, title: "Apply blocked", message: message}
  end

  defp notice_from_issue(%Issue{id: :missing_artifact_id, detail: message}) do
    %Notice{tone: :error, title: "Missing id", message: message}
  end

  defp notice_from_issue(%Issue{id: :apply_blocked_old_code, detail: %{count: count}}) do
    %Notice{
      tone: :warning,
      title: "Apply blocked",
      message:
        "Old code is still draining in #{count} process(es). Retry once they leave the previous module."
    }
  end

  defp notice_from_issue(%Issue{
         id: :apply_module_mismatch,
         detail: %{driver_id: driver_id, expected: expected, actual: actual}
       }) do
    %Notice{
      tone: :error,
      title: "Apply blocked",
      message:
        "Logical id #{driver_id} is already bound to #{inspect(expected)} and cannot switch to #{inspect(actual)} in latest-only mode."
    }
  end

  defp notice_from_issue(%Issue{id: :apply_failed, detail: message}) do
    %Notice{
      tone: :error,
      title: "Apply failed",
      message: "Runtime rejected the built artifact: #{message}"
    }
  end

  defp format_error(%Zoi.Error{path: path, message: message}) do
    case path do
      [] -> message
      _ -> "#{format_error_path(path)}: #{message}"
    end
  end

  defp format_error(%{field: field, message: message}), do: "#{field}: #{message}"
  defp format_error(other), do: inspect(other)

  defp format_diagnostic(%{file: file, position: position, message: message}),
    do: "#{file}:#{inspect(position)} #{message}"

  defp format_diagnostic(%{message: message}), do: message
  defp format_diagnostic(other) when is_binary(other), do: other
  defp format_diagnostic(other), do: inspect(other)

  defp format_error_path(path) do
    path
    |> Enum.map(fn
      key when is_integer(key) -> "[#{key}]"
      key when is_atom(key) -> Atom.to_string(key)
      key -> to_string(key)
    end)
    |> Enum.reduce("", fn segment, acc ->
      cond do
        acc == "" ->
          segment

        String.starts_with?(segment, "[") ->
          acc <> segment

        true ->
          acc <> "." <> segment
      end
    end)
  end
end
