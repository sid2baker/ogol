defmodule Ogol.HMIWeb.Components.StudioCell do
  use Ogol.HMIWeb, :html

  @moduledoc """
  First-principles Studio Cell primitives.

  A Studio Cell is the interaction surface for one bounded, source-backed
  artifact.

  This module is the shared UI shell for that concept. The paired state and
  derivation contract lives in `Ogol.Studio.Cell`.

  This module intentionally owns only the shared surface contract:

  - header left: available actions
  - header middle: top-priority notice
  - header right: available views
  - body: the selected projection of the artifact

  The header answers three questions:

  - what can I do now?
  - what do I most need to know?
  - how can I view this right now?

  The body renders the selected view. Different runtime or lifecycle states may
  produce different presentations inside the same view, but they are still
  presentations of the same source-backed artifact.

  It intentionally does not own:

  - source or model state
  - action availability logic
  - desired or observed state
  - runtime summaries
  - side rails, banners, pickers, or footers

  Those concerns belong to the concrete cell implementation.
  """

  attr(:class, :string, default: nil)
  attr(:panel_class, :string, default: nil)
  attr(:body_class, :string, default: nil)
  attr(:rest, :global)

  slot(:actions,
    doc: "Transitions that are valid now for the current artifact state."
  )

  slot(:notice,
    doc: "The single highest-priority explanation the user should see right now."
  )

  slot(:views,
    doc: "The currently available representations, such as Visual and Source."
  )

  slot(:body,
    required: true,
    doc: "The selected representation of the source-backed artifact."
  )

  def cell(assigns) do
    ~H"""
    <% notice = List.first(@notice) %>

    <section class={["w-full", @class]} {@rest}>
      <section class={["app-panel flex min-h-0 w-full flex-col gap-4 px-5 py-5", @panel_class]}>
        <header class="grid w-full gap-3 xl:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto] xl:items-start">
          <div class="flex min-w-0 flex-wrap items-center gap-2 xl:justify-self-start">
            <%= for action <- @actions do %>
              {render_slot(action)}
            <% end %>
          </div>

          <div :if={notice} class="min-w-0 xl:px-3 xl:justify-self-stretch">
            {render_slot(notice)}
          </div>

          <div class="flex min-w-0 flex-wrap items-center gap-2 xl:justify-self-end">
            <%= for view <- @views do %>
              {render_slot(view)}
            <% end %>
          </div>
        </header>

        <div class={["grid min-h-0 w-full flex-1 items-stretch", @body_class]}>
          <%= for body <- @body do %>
            {render_slot(body)}
          <% end %>
        </div>
      </section>
    </section>
    """
  end

  attr(:tone, :atom,
    values: [:info, :warn, :warning, :error, :success, :good, :danger],
    default: :info
  )

  attr(:title, :string, required: true)
  attr(:message, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block)

  def notice(assigns) do
    ~H"""
    <div class={[notice_classes(@tone), @class]}>
      <p class="truncate font-semibold">{@title}</p>
      <p :if={@message} class="truncate text-sm text-current/85">{@message}</p>
      <div :if={@inner_block != []} class="text-sm text-current/85">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:variant, :atom, values: [:primary, :secondary, :danger], default: :secondary)
  attr(:rest, :global, include: ~w(type disabled form name value))
  slot(:inner_block, required: true)

  def action_button(assigns) do
    ~H"""
    <button class={action_button_classes(@variant)} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr(:selected, :boolean, required: true)
  attr(:available, :boolean, default: true)
  attr(:rest, :global, include: ~w(type disabled form name value))
  slot(:inner_block, required: true)

  def view_button(assigns) do
    ~H"""
    <button class={view_button_classes(@selected, @available)} disabled={!@available} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp action_button_classes(:primary),
    do: "app-button disabled:cursor-not-allowed disabled:opacity-60"

  defp action_button_classes(:danger),
    do:
      "rounded-xl border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-4 py-2 text-sm font-medium text-[var(--app-danger-text)] transition hover:opacity-90 disabled:cursor-not-allowed disabled:opacity-60"

  defp action_button_classes(:secondary),
    do: "app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"

  defp view_button_classes(true, true), do: "app-button"
  defp view_button_classes(false, true), do: "app-button-secondary"
  defp view_button_classes(true, false), do: "app-button cursor-not-allowed opacity-60"
  defp view_button_classes(false, false), do: "app-button-secondary cursor-not-allowed opacity-60"

  defp notice_classes(:warn),
    do:
      "rounded-xl border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-3 py-2 text-center text-[var(--app-warn-text)]"

  defp notice_classes(:warning),
    do:
      "rounded-xl border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-3 py-2 text-center text-[var(--app-warn-text)]"

  defp notice_classes(:info),
    do:
      "rounded-xl border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-3 py-2 text-center text-[var(--app-info-text)]"

  defp notice_classes(:success),
    do:
      "rounded-xl border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-3 py-2 text-center text-[var(--app-good-text)]"

  defp notice_classes(:good),
    do:
      "rounded-xl border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-3 py-2 text-center text-[var(--app-good-text)]"

  defp notice_classes(:error),
    do:
      "rounded-xl border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-3 py-2 text-center text-[var(--app-danger-text)]"

  defp notice_classes(:danger),
    do:
      "rounded-xl border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-3 py-2 text-center text-[var(--app-danger-text)]"
end
