defmodule OgolWeb.Studio.Library do
  use OgolWeb, :html

  @moduledoc false

  attr(:title, :string, required: true)
  attr(:items, :list, default: [])
  attr(:current_id, :string, default: nil)
  attr(:empty_label, :string, default: "No artifacts available.")
  attr(:class, :string, default: nil)

  slot(:actions)

  def list(assigns) do
    ~H"""
    <aside class={["app-panel px-4 py-4", @class]}>
      <div class="flex items-center justify-between gap-3">
        <div>
          <p class="app-kicker">{@title}</p>
          <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            Select an available artifact to edit it in the Studio Cell.
          </p>
        </div>

        <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
          {render_slot(@actions)}
        </div>
      </div>

      <div class="mt-4 space-y-2">
        <div
          :if={@items == []}
          class="rounded-2xl border border-dashed border-[var(--app-border)] px-4 py-4 text-sm leading-6 text-[var(--app-text-muted)]"
        >
          {@empty_label}
        </div>

        <.link
          :for={item <- @items}
          patch={item.path}
          class={item_classes(item.id == @current_id)}
        >
          <div class="min-w-0">
            <p class="truncate text-sm font-semibold text-[var(--app-text)]">{item.label}</p>
            <p :if={item[:detail]} class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">
              {item.detail}
            </p>
          </div>

          <span
            :if={item[:status]}
            class="rounded-full border border-[var(--app-border)] px-2 py-0.5 text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]"
          >
            {item.status}
          </span>
        </.link>
      </div>
    </aside>
    """
  end

  defp item_classes(true) do
    [
      "flex items-start justify-between gap-3 rounded-2xl border px-4 py-3 transition",
      "border-[var(--app-accent)] bg-[var(--app-surface-alt)] shadow-[0_0_0_1px_var(--app-accent)]"
    ]
  end

  defp item_classes(false) do
    [
      "flex items-start justify-between gap-3 rounded-2xl border px-4 py-3 transition",
      "border-[var(--app-border)] bg-[var(--app-surface-alt)] hover:border-[var(--app-accent)]/50"
    ]
  end
end
