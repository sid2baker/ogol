defmodule Ogol.HMIWeb.Components.MachineCard do
  use Ogol.HMIWeb, :html

  alias Ogol.HMIWeb.Components.StatusBadge

  attr(:machine, :map, required: true)
  attr(:status, :map, default: nil)
  attr(:skills, :list, default: [])
  attr(:controls_enabled?, :boolean, default: false)

  def card(assigns) do
    assigns =
      assigns
      |> Map.put(:machine_id, format_machine_id(assigns.machine.machine_id))
      |> Map.put(:status, assigns.status || fallback_status(assigns.machine))
      |> Map.put(:io_groups, io_groups(assigns.status || fallback_status(assigns.machine)))
      |> Map.put(:machine_markers, machine_markers(assigns.machine))

    ~H"""
    <article class="app-panel p-4">
      <div class="flex flex-col gap-3 border-b border-[var(--app-border)] pb-3 xl:flex-row xl:items-start xl:justify-between">
        <div class="min-w-0">
          <p class="app-kicker">
            Machine Registry
          </p>
          <div class="mt-1 flex flex-wrap items-center gap-2">
            <.link navigate={~p"/ops/machines/#{@machine_id}"} class="text-lg font-semibold tracking-tight text-[var(--app-text)] underline decoration-[var(--app-border-strong)] underline-offset-4">
              {@machine_id}
            </.link>
            <span class={link_classes(@machine.connected?)}>
              {format_connected(@machine.connected?)}
            </span>
          </div>
          <p class="mt-1 truncate font-mono text-[11px] text-[var(--app-text-dim)]">{format_module(@machine.module)}</p>
        </div>

        <div class="flex flex-wrap items-center gap-2 xl:justify-end">
          <div class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2 text-right">
            <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Last Transition</p>
            <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">{format_timestamp(@machine.last_transition_at)}</p>
          </div>
          <StatusBadge.badge status={@machine.health} />
        </div>
      </div>

      <div class="mt-3 grid gap-3 2xl:grid-cols-[minmax(0,0.95fr)_minmax(0,1.05fr)]">
        <dl class="grid gap-2 sm:grid-cols-2">
          <.stat_cell label="State" value={format_term(@status.current_state, "unknown")} />
          <.stat_cell label="Last Signal" value={format_term(@status.last_signal, "none")} />
          <.stat_cell label="Public Facts" value={map_size(@status.facts)} />
          <.stat_cell label="Public Fields" value={map_size(@status.fields)} />
          <.stat_cell label="Public Outputs" value={map_size(@status.outputs)} />
          <.stat_cell label="Observed Machines" value={length(@machine.dependencies)} />
          <.stat_cell label="Alarms" value={length(@machine.alarms)} />
          <.stat_cell label="Faults" value={length(@machine.faults)} />
          <.stat_cell label="Restarts" value={@machine.restart_count} />
          <.stat_cell label="Adapter" value={preview_count(@machine.adapter_status)} />
        </dl>

        <div class="grid gap-2 sm:grid-cols-2 2xl:grid-cols-4">
          <.io_group :for={group <- @io_groups} title={group.title} entries={group.entries} empty_label={group.empty_label} />
        </div>
      </div>

      <div :if={@machine_markers != []} class="mt-3 flex flex-wrap gap-2 border-t border-[var(--app-border)] pt-3">
        <span
          :for={marker <- @machine_markers}
          class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-2 py-1 font-mono text-[11px] text-[var(--app-text-muted)]"
        >
          {marker}
        </span>
      </div>

      <section :if={@skills != []} class="mt-3 border-t border-[var(--app-border)] pt-3">
        <div class="flex flex-col gap-3 xl:flex-row xl:items-start xl:justify-between">
          <div class="max-w-xs">
            <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Controls</p>
            <p class="mt-1 text-[11px] leading-5 text-[var(--app-text-muted)]">
              Invokable machine skills. Signals are observed separately.
            </p>
            <.link
              navigate={~p"/ops/machines/#{@machine_id}"}
              class="mt-2 inline-flex border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-2 py-1 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text)] transition hover:border-[var(--app-border-strong)]"
            >
              Open detail
            </.link>
          </div>

          <div class="min-w-0 flex-1 space-y-2">
            <div>
              <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Skills</p>
              <div class="mt-1 flex flex-wrap gap-2">
                <button
                  :for={skill <- @skills}
                  type="button"
                  phx-click="dispatch_control"
                  phx-value-machine_id={@machine_id}
                  phx-value-name={to_string(skill.name)}
                  disabled={!@controls_enabled? or skill.available? == false}
                  data-test={"control-#{@machine_id}-skill-#{skill.name}"}
                  class={control_button_classes(@controls_enabled? and skill.available? != false)}
                  title={skill.summary || format_skill_name(skill.name)}
                >
                  {format_skill_name(skill.name)}
                </button>
              </div>
            </div>

            <p :if={!@controls_enabled?} class="font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
              Runtime offline; controls locked
            </p>
          </div>
        </div>
      </section>
    </article>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  def stat_cell(assigns) do
    ~H"""
    <div class="border border-white/8 bg-slate-900/70 px-3 py-2.5">
      <dt class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">{@label}</dt>
      <dd class="mt-1 truncate text-sm font-semibold text-[var(--app-text)]">{@value}</dd>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:empty_label, :string, required: true)

  def io_group(assigns) do
    ~H"""
    <section class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2.5">
      <div class="flex items-center justify-between gap-2">
        <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">{@title}</p>
        <span class="text-[10px] text-[var(--app-text-dim)]">{length(@entries)}</span>
      </div>

      <div class="mt-2 space-y-1.5">
        <div :if={@entries == []} class="font-mono text-[11px] text-[var(--app-text-dim)]">{@empty_label}</div>

        <div :for={{key, value} <- @entries} class="flex items-center justify-between gap-3 text-[11px]">
          <span class="truncate font-mono uppercase tracking-[0.18em] text-[var(--app-text-dim)]">{key}</span>
          <span class="truncate text-right text-[var(--app-text)]">{value}</span>
        </div>
      </div>
    </section>
    """
  end

  defp link_classes(true) do
    "border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--app-good-text)]"
  end

  defp link_classes(false) do
    "border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-2 py-1 font-mono text-[10px] font-semibold uppercase tracking-[0.18em] text-[var(--app-text)]"
  end

  defp format_connected(true), do: "linked"
  defp format_connected(false), do: "offline"

  defp control_button_classes(false) do
    "cursor-not-allowed border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-2.5 py-1.5 font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--app-text-dim)]"
  end

  defp control_button_classes(true) do
    "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-2.5 py-1.5 font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--app-info-text)] transition hover:bg-[#1b3a5c]"
  end

  defp format_module(nil), do: "module pending"
  defp format_module(module), do: module |> inspect() |> String.replace_prefix("Elixir.", "")

  defp format_machine_id(machine_id), do: to_string(machine_id)
  defp format_skill_name(name), do: name |> to_string() |> String.replace("_", " ")

  defp format_term(nil, fallback), do: fallback
  defp format_term(value, _fallback) when is_atom(value), do: Atom.to_string(value)
  defp format_term(value, _fallback), do: format_value(value)

  defp format_value(value) when is_binary(value), do: truncate(value, 28)
  defp format_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_value(value) when is_boolean(value), do: to_string(value)
  defp format_value(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp format_value(value), do: value |> inspect(limit: 4) |> truncate(28)

  defp format_timestamp(nil), do: "n/a"

  defp format_timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp preview_count(map) when map == %{}, do: "0"
  defp preview_count(map) when is_map(map), do: map_size(map)

  defp io_groups(status) do
    [
      %{title: "Facts", entries: preview_entries(status.facts), empty_label: "No public facts"},
      %{
        title: "Fields",
        entries: preview_entries(status.fields),
        empty_label: "No public fields"
      },
      %{
        title: "Outputs",
        entries: preview_entries(status.outputs),
        empty_label: "No public outputs"
      }
    ]
  end

  defp fallback_status(machine) do
    %{
      current_state: machine.current_state,
      last_signal: machine.last_signal,
      facts: %{},
      fields: %{},
      outputs: %{}
    }
  end

  defp preview_entries(map, limit \\ 3)

  defp preview_entries(map, _limit) when map == %{}, do: []

  defp preview_entries(map, limit) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.take(limit)
    |> Enum.map(fn {key, value} -> {to_string(key), format_value(value)} end)
  end

  defp machine_markers(machine) do
    []
    |> maybe_append(
      "started #{format_age(machine.meta[:last_started_at])}",
      machine.meta[:last_started_at]
    )
    |> maybe_append(
      "stop #{format_value(machine.meta[:stop_reason])}",
      machine.meta[:stop_reason]
    )
    |> maybe_append(latest_fault_marker(machine.faults), machine.faults != [])
    |> maybe_append(adapter_marker(machine.adapter_status), machine.adapter_status != %{})
  end

  defp latest_fault_marker([fault | _rest]) do
    "fault #{format_value(Map.get(fault, :reason) || Map.get(fault, "reason") || :unknown)}"
  end

  defp latest_fault_marker([]), do: nil

  defp adapter_marker(adapter_status) when adapter_status == %{}, do: nil
  defp adapter_marker(adapter_status), do: "adapter #{adapter_summary(adapter_status)}"

  defp maybe_append(list, nil, _condition), do: list
  defp maybe_append(list, _value, nil), do: list
  defp maybe_append(list, _value, false), do: list
  defp maybe_append(list, value, _condition), do: [value | list]

  defp format_age(nil), do: "n/a"

  defp format_age(value) when is_integer(value) do
    diff = max(System.system_time(:millisecond) - value, 0)

    cond do
      diff < 1_000 -> "#{diff} ms"
      diff < 60_000 -> "#{div(diff, 1_000)} s"
      diff < 3_600_000 -> "#{div(diff, 60_000)} m"
      true -> "#{div(diff, 3_600_000)} h"
    end
  end

  defp adapter_summary(adapter_status) do
    adapter_status
    |> preview_entries(2)
    |> Enum.map_join(", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp truncate(value, max_length) when byte_size(value) <= max_length, do: value
  defp truncate(value, max_length), do: String.slice(value, 0, max_length - 3) <> "..."
end
