defmodule OgolWeb.HMI.OpsControlStrip do
  use OgolWeb, :html

  attr(:status, :map, required: true)
  attr(:feedback, :map, default: nil)

  def strip(assigns) do
    ~H"""
    <section
      data-test="ops-control-strip"
      class="app-panel flex flex-col gap-4 px-4 py-4 xl:flex-row xl:items-start xl:justify-between"
    >
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <p class="app-kicker">Global Control</p>
          <span class={chip_classes(mode_tone(@status.control_mode))}>
            {mode_label(@status.control_mode)}
          </span>
          <span class={chip_classes(:neutral)}>
            {owner_label(@status.owner_kind)}
          </span>
          <span :if={@status.active_run} class={chip_classes(:info)}>
            {active_run_label(@status.active_run)}
          </span>
        </div>

        <p class="mt-2 max-w-4xl text-sm leading-6 text-[var(--app-text-muted)]">
          {summary(@status)}
        </p>

        <div
          :if={@feedback}
          class={[
            "mt-3 inline-flex border px-3 py-2 font-mono text-[11px] uppercase tracking-[0.16em]",
            feedback_classes(@feedback.status)
          ]}
        >
          {feedback_summary(@feedback)}
        </div>
      </div>

      <div class="flex flex-wrap items-center gap-2 xl:justify-end">
        <button
          type="button"
          phx-click="ops_control"
          phx-value-action="arm_auto"
          disabled={!@status.actions.arm_auto?}
          data-test="ops-control-arm-auto"
          class={button_classes(@status.actions.arm_auto?)}
        >
          Arm Auto
        </button>
        <button
          type="button"
          phx-click="ops_control"
          phx-value-action="switch_to_manual"
          disabled={!@status.actions.switch_to_manual?}
          data-test="ops-control-switch-to-manual"
          class={button_classes(@status.actions.switch_to_manual?)}
        >
          Manual
        </button>
        <button
          :if={@status.actions.request_manual_takeover?}
          type="button"
          phx-click="ops_control"
          phx-value-action="request_manual_takeover"
          data-test="ops-control-request-manual-takeover"
          class={button_classes(true)}
        >
          Request Manual Takeover
        </button>
      </div>
    </section>
    """
  end

  defp summary(%{active_run: %{sequence_id: sequence_id, status: status}, owner_kind: owner_kind}) do
    "#{owner_label(owner_kind)} owns the cell. Active procedure #{sequence_id} is #{format_value(status)}."
  end

  defp summary(%{pending_intent: %{takeover_requested?: true}}) do
    "Manual takeover has been requested. The cell will return to operator control when the procedure releases ownership."
  end

  defp summary(%{control_mode: :auto, owner_kind: :manual_operator}) do
    "Auto is armed. Procedure admission remains under Auto, while operator machine commands are gated until Manual is restored."
  end

  defp summary(%{control_mode: :manual}) do
    "Manual operator owns the cell. Machine skills remain available subject to runtime connectivity and safety policy."
  end

  defp summary(_status) do
    "Cell ownership and runtime posture are managed centrally from session truth."
  end

  defp feedback_summary(%{status: :ok, action: action, detail: detail}) do
    "#{humanize_action(action)}: #{format_value(detail)}"
  end

  defp feedback_summary(%{status: :error, action: action, detail: detail}) do
    "#{humanize_action(action)} denied: #{format_value(detail)}"
  end

  defp humanize_action(action) do
    action
    |> to_string()
    |> String.replace("_", " ")
  end

  defp mode_label(:auto), do: "Auto"
  defp mode_label(_other), do: "Manual"

  defp owner_label(:manual_operator), do: "Operator"
  defp owner_label(:procedure), do: "Procedure"
  defp owner_label(:manual_takeover_pending), do: "Takeover Pending"
  defp owner_label(other), do: format_value(other)

  defp active_run_label(%{sequence_id: sequence_id, status: status}) do
    "#{sequence_id} / #{format_value(status)}"
  end

  defp chip_classes(:good) do
    "border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-2 py-1 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-good-text)]"
  end

  defp chip_classes(:info) do
    "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-2 py-1 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-info-text)]"
  end

  defp chip_classes(:warn) do
    "border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-2 py-1 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-warn-text)]"
  end

  defp chip_classes(:neutral) do
    "border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-2 py-1 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-muted)]"
  end

  defp mode_tone(:auto), do: :warn
  defp mode_tone(_other), do: :good

  defp button_classes(true) do
    "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--app-info-text)] transition hover:bg-[#1b3a5c]"
  end

  defp button_classes(false) do
    "cursor-not-allowed border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--app-text-dim)]"
  end

  defp feedback_classes(:ok) do
    "border-[var(--app-good-border)] bg-[var(--app-good-surface)] text-[var(--app-good-text)]"
  end

  defp feedback_classes(:error) do
    "border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"
  end

  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp format_value(value), do: inspect(value)
end
