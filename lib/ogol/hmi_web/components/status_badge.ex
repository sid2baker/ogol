defmodule Ogol.HMIWeb.Components.StatusBadge do
  use Ogol.HMIWeb, :html

  attr(:status, :atom, required: true)
  attr(:class, :string, default: "")

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center border px-2.5 py-1 font-mono text-[11px] font-semibold uppercase tracking-[0.26em]",
      badge_classes(@status),
      @class
    ]}>
      <span class={["mr-1.5 h-1.5 w-1.5", dot_classes(@status)]}></span>
      {format_status(@status)}
    </span>
    """
  end

  defp format_status(status), do: status |> to_string() |> String.replace("_", " ")

  defp badge_classes(status) when status in [:healthy, :running] do
    "border-emerald-400/35 bg-emerald-400/10 text-emerald-50"
  end

  defp badge_classes(status) when status in [:waiting, :recovering] do
    "border-amber-400/35 bg-amber-400/10 text-amber-50"
  end

  defp badge_classes(status) when status in [:faulted, :crashed] do
    "border-rose-400/35 bg-rose-400/10 text-rose-50"
  end

  defp badge_classes(status) when status in [:stale, :disconnected, :stopped] do
    "border-slate-400/30 bg-slate-400/10 text-slate-100"
  end

  defp badge_classes(_status), do: "border-cyan-400/30 bg-cyan-400/10 text-cyan-50"

  defp dot_classes(status) when status in [:healthy, :running],
    do: "bg-emerald-300 shadow-[0_0_10px_rgba(52,211,153,0.7)]"

  defp dot_classes(status) when status in [:waiting, :recovering],
    do: "bg-amber-300 shadow-[0_0_10px_rgba(252,211,77,0.65)]"

  defp dot_classes(status) when status in [:faulted, :crashed],
    do: "bg-rose-300 shadow-[0_0_10px_rgba(253,164,175,0.65)]"

  defp dot_classes(_status), do: "bg-slate-300"
end
