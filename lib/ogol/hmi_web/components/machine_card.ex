defmodule Ogol.HMIWeb.Components.MachineCard do
  use Ogol.HMIWeb, :html

  alias Ogol.HMIWeb.Components.StatusBadge

  attr(:machine, :map, required: true)

  def card(assigns) do
    ~H"""
    <article class="rounded-3xl border border-white/10 bg-slate-900/70 p-5 shadow-[0_20px_80px_-40px_rgba(14,165,233,0.45)] backdrop-blur">
      <div class="flex items-start justify-between gap-4">
        <div>
          <p class="text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">Machine</p>
          <h3 class="mt-1 text-lg font-semibold text-white">{@machine.machine_id}</h3>
          <p class="mt-1 text-sm text-slate-400">{format_module(@machine.module)}</p>
        </div>

        <StatusBadge.badge status={@machine.health} />
      </div>

      <dl class="mt-5 grid grid-cols-2 gap-4 text-sm">
        <div class="rounded-2xl border border-white/8 bg-slate-950/60 p-3">
          <dt class="text-xs uppercase tracking-wide text-slate-500">State</dt>
          <dd class="mt-1 font-medium text-slate-100">{@machine.current_state || "unknown"}</dd>
        </div>
        <div class="rounded-2xl border border-white/8 bg-slate-950/60 p-3">
          <dt class="text-xs uppercase tracking-wide text-slate-500">Last Signal</dt>
          <dd class="mt-1 font-medium text-slate-100">{@machine.last_signal || "none"}</dd>
        </div>
        <div class="rounded-2xl border border-white/8 bg-slate-950/60 p-3">
          <dt class="text-xs uppercase tracking-wide text-slate-500">Facts</dt>
          <dd class="mt-1 font-medium text-slate-100">{map_size(@machine.facts)}</dd>
        </div>
        <div class="rounded-2xl border border-white/8 bg-slate-950/60 p-3">
          <dt class="text-xs uppercase tracking-wide text-slate-500">Outputs</dt>
          <dd class="mt-1 font-medium text-slate-100">{map_size(@machine.outputs)}</dd>
        </div>
      </dl>

      <div class="mt-5 flex items-center justify-between text-xs text-slate-400">
        <span>Connected: {format_connected(@machine.connected?)}</span>
        <span>Restarts: {@machine.restart_count}</span>
      </div>
    </article>
    """
  end

  defp format_connected(true), do: "yes"
  defp format_connected(false), do: "no"

  defp format_module(nil), do: "module pending"
  defp format_module(module), do: inspect(module)
end
