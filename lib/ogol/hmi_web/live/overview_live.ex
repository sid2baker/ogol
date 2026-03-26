defmodule Ogol.HMIWeb.OverviewLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.{Bus, EventLog, SnapshotStore}
  alias Ogol.HMIWeb.Components.{MachineCard, StatusBadge}

  @event_limit 14

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Bus.subscribe(Bus.overview_topic())
      :ok = Bus.subscribe(Bus.events_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Overview")
     |> assign(:event_limit, @event_limit)
     |> assign(:machines, SnapshotStore.list_machines())
     |> assign(:events, EventLog.recent(@event_limit))}
  end

  @impl true
  def handle_info({:machine_snapshot_updated, _snapshot}, socket) do
    {:noreply, assign(socket, :machines, SnapshotStore.list_machines())}
  end

  def handle_info({:event_logged, _notification}, socket) do
    {:noreply, assign(socket, :events, EventLog.recent(@event_limit))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-8">
      <div class="flex flex-col gap-4 lg:flex-row lg:items-end lg:justify-between">
        <div>
          <p class="text-sm font-medium uppercase tracking-[0.24em] text-cyan-300">Overview</p>
          <h2 class="mt-2 text-3xl font-semibold text-white">Machine runtime surface</h2>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-slate-300">
            Live projections of generated machine brains, their current health, and recent runtime activity.
          </p>
        </div>

        <div class="flex items-center gap-3">
          <StatusBadge.badge status={summary_health(@machines)} />
          <div class="rounded-2xl border border-white/10 bg-slate-900/60 px-4 py-3 text-right">
            <p class="text-xs uppercase tracking-wide text-slate-500">Machines</p>
            <p class="text-2xl font-semibold text-white">{length(@machines)}</p>
          </div>
        </div>
      </div>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,2fr)_minmax(20rem,1fr)]">
        <section>
          <div :if={@machines == []} class="rounded-3xl border border-dashed border-white/15 bg-slate-900/50 px-6 py-14 text-center">
            <h3 class="text-lg font-semibold text-white">No machines running yet</h3>
            <p class="mt-2 text-sm text-slate-400">
              Start a generated Ogol machine and it will appear here automatically.
            </p>
          </div>

          <div :if={@machines != []} class="grid gap-5 md:grid-cols-2 2xl:grid-cols-3">
            <MachineCard.card :for={machine <- @machines} machine={machine} />
          </div>
        </section>

        <aside class="rounded-3xl border border-white/10 bg-slate-900/70 p-5 backdrop-blur">
          <div class="flex items-center justify-between">
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.22em] text-slate-400">Event Log</p>
              <h3 class="mt-1 text-lg font-semibold text-white">Recent runtime notifications</h3>
            </div>
            <span class="rounded-full border border-white/10 bg-slate-950/70 px-3 py-1 text-xs text-slate-300">
              {@event_limit} latest
            </span>
          </div>

          <div class="mt-5 space-y-3">
            <div :if={@events == []} class="rounded-2xl border border-dashed border-white/10 px-4 py-6 text-sm text-slate-400">
              No runtime notifications yet.
            </div>

            <article
              :for={event <- Enum.reverse(@events)}
              class="rounded-2xl border border-white/8 bg-slate-950/60 px-4 py-3"
            >
              <div class="flex items-start justify-between gap-4">
                <div>
                  <p class="text-sm font-medium text-slate-100">{format_event_type(event.type)}</p>
                  <p class="mt-1 text-xs text-slate-400">
                    {event.machine_id || event.topology_id || event.meta[:endpoint_id] || "system"}
                  </p>
                </div>
                <p class="text-xs text-slate-500">{format_timestamp(event.occurred_at)}</p>
              </div>
            </article>
          </div>
        </aside>
      </div>
    </section>
    """
  end

  defp summary_health([]), do: :stopped
  defp summary_health(machines), do: machines |> Enum.map(& &1.health) |> choose_summary_health()

  defp choose_summary_health(statuses) do
    cond do
      Enum.any?(statuses, &(&1 in [:crashed, :faulted])) -> :crashed
      Enum.any?(statuses, &(&1 == :recovering)) -> :recovering
      Enum.any?(statuses, &(&1 == :running)) -> :running
      Enum.any?(statuses, &(&1 == :waiting)) -> :waiting
      Enum.any?(statuses, &(&1 == :healthy)) -> :healthy
      true -> :stopped
    end
  end

  defp format_event_type(type), do: type |> to_string() |> String.replace("_", " ")

  defp format_timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp format_timestamp(_), do: "n/a"
end
