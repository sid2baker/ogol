defmodule OgolWeb.Components.StatusBadge do
  use OgolWeb, :html

  attr(:status, :atom, required: true)
  attr(:class, :string, default: "")

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center border px-2.5 py-1 font-mono text-[11px] font-semibold uppercase tracking-[0.2em]",
      badge_classes(@status),
      @class
    ]}>
      <span class={["mr-1.5 h-2 w-2", dot_classes(@status)]}></span>
      {format_status(@status)}
    </span>
    """
  end

  defp format_status(status), do: status |> to_string() |> String.replace("_", " ")

  defp badge_classes(status) when status in [:healthy, :running] do
    "border-[var(--app-good-border)] bg-[var(--app-good-surface)] text-[var(--app-good-text)]"
  end

  defp badge_classes(status) when status in [:waiting, :recovering] do
    "border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] text-[var(--app-warn-text)]"
  end

  defp badge_classes(status) when status in [:faulted, :crashed] do
    "border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"
  end

  defp badge_classes(status) when status in [:stale, :disconnected, :stopped] do
    "border-[var(--app-border-strong)] bg-[var(--app-surface-strong)] text-[var(--app-text)]"
  end

  defp badge_classes(_status),
    do: "border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]"

  defp dot_classes(status) when status in [:healthy, :running], do: "bg-emerald-300"

  defp dot_classes(status) when status in [:waiting, :recovering], do: "bg-amber-300"

  defp dot_classes(status) when status in [:faulted, :crashed], do: "bg-rose-300"

  defp dot_classes(_status), do: "bg-slate-300"
end
