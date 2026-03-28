defmodule Ogol.HMIWeb.Components.StudioCell do
  use Ogol.HMIWeb, :html

  @moduledoc false

  attr(:kicker, :string, default: nil)
  attr(:title, :string, default: nil)
  attr(:summary, :string, default: nil)
  attr(:max_width, :string, default: "max-w-7xl")
  attr(:outer_class, :string, default: nil)
  attr(:panel_class, :string, default: nil)
  attr(:body_class, :string, default: nil)
  attr(:rest, :global)

  slot(:actions)
  slot(:notice)
  slot(:modes)
  slot(:runtime)
  slot(:picker)
  slot(:banners)
  slot(:inner_block, required: true)
  slot(:footer)

  def cell(assigns) do
    ~H"""
    <section class={["mx-auto", @max_width, @outer_class]} {@rest}>
      <section class={["app-panel px-5 py-5", @panel_class]}>
        <div class={["flex flex-col gap-4", @body_class]}>
          <div class="flex flex-col gap-3 xl:flex-row xl:items-start">
            <div :if={@actions != []} class="flex flex-wrap items-center gap-2">
              {render_slot(@actions)}
            </div>

            <div :if={@notice != []} class="min-w-0 xl:flex-1 xl:px-2">
              {render_slot(@notice)}
            </div>

            <div :if={@modes != []} class="flex flex-wrap gap-2 xl:ml-auto">
              {render_slot(@modes)}
            </div>
          </div>

          <div :if={@picker != []}>
            {render_slot(@picker)}
          </div>

          {render_slot(@inner_block)}

          <div :if={@runtime != []}>
            {render_slot(@runtime)}
          </div>

          <div :for={banner <- @banners}>
            {render_slot(banner)}
          </div>

          <div :if={@footer != []} class="mt-5 border-t border-[var(--app-border)] pt-5">
            {render_slot(@footer)}
          </div>
        </div>
      </section>
    </section>
    """
  end

  attr(:title, :string, default: "Runtime")
  attr(:summary, :string, required: true)
  attr(:class, :string, default: nil)
  attr(:rest, :global)

  slot :fact do
    attr(:label, :string, required: true)
    attr(:value, :string)
  end

  slot(:inner_block)

  def runtime_panel(assigns) do
    ~H"""
    <div class={["rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4", @class]} {@rest}>
      <p class="app-kicker">{@title}</p>
      <p class="mt-2 text-sm font-semibold text-[var(--app-text)]">
        {@summary}
      </p>
      <dl :if={@fact != []} class="mt-3 grid gap-3 text-sm leading-6 text-[var(--app-text-muted)]">
        <div :for={fact <- @fact}>
          <dt class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
            {fact.label}
          </dt>
          <dd class="mt-1 break-all text-[var(--app-text)]">
            {fact[:value] || render_slot(fact)}
          </dd>
        </div>
      </dl>
      <div :if={@inner_block != []} class="mt-3">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:level, :atom, required: true)
  attr(:title, :string, required: true)
  attr(:detail, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block)

  def banner(assigns) do
    ~H"""
    <div class={[banner_classes(@level), @class]}>
      <p class="font-semibold">{@title}</p>
      <p :if={@detail} class="mt-1 text-sm leading-6">{@detail}</p>
      <div :if={@inner_block != []} class="mt-1 text-sm leading-6">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr(:level, :atom, required: true)
  attr(:title, :string, required: true)
  attr(:detail, :string, default: nil)
  attr(:class, :string, default: nil)

  def notice(assigns) do
    ~H"""
    <div class={[notice_classes(@level), @class]}>
      <p class="truncate font-semibold">{@title}</p>
      <p :if={@detail} class="truncate text-sm text-current/85">{@detail}</p>
    </div>
    """
  end

  attr(:active, :boolean, required: true)
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def toggle_button(assigns) do
    ~H"""
    <button class={toggle_button_classes(@active)} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp toggle_button_classes(true), do: "app-button"
  defp toggle_button_classes(false), do: "app-button-secondary"

  defp banner_classes(:warn),
    do:
      "rounded-2xl border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-4 py-4 text-[var(--app-warn-text)]"

  defp banner_classes(:info),
    do:
      "rounded-2xl border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-4 py-4 text-[var(--app-info-text)]"

  defp banner_classes(:good),
    do:
      "rounded-2xl border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-4 py-4 text-[var(--app-good-text)]"

  defp banner_classes(_other),
    do:
      "rounded-2xl border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-4 py-4 text-[var(--app-danger-text)]"

  defp notice_classes(:warn),
    do:
      "rounded-xl border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-3 py-2 text-center text-[var(--app-warn-text)]"

  defp notice_classes(:info),
    do:
      "rounded-xl border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-3 py-2 text-center text-[var(--app-info-text)]"

  defp notice_classes(:good),
    do:
      "rounded-xl border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-3 py-2 text-center text-[var(--app-good-text)]"

  defp notice_classes(_other),
    do:
      "rounded-xl border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-3 py-2 text-center text-[var(--app-danger-text)]"
end
