defmodule Ogol.HMIWeb.Components.StudioCell do
  use Ogol.HMIWeb, :html

  @moduledoc false

  attr(:max_width, :string, default: "max-w-7xl")
  attr(:outer_class, :string, default: nil)
  attr(:panel_class, :string, default: nil)
  attr(:body_class, :string, default: nil)
  attr(:content_class, :string, default: nil)
  attr(:rest, :global)

  slot(:actions)
  slot(:notice)
  slot(:modes)
  slot(:inner_block, required: true)

  def cell(assigns) do
    ~H"""
    <section class={["mx-auto w-full", @max_width, @outer_class]} {@rest}>
      <section class={["app-panel w-full px-5 py-5", @panel_class]}>
        <div class={["flex w-full min-h-0 flex-col gap-4", @body_class]}>
          <div class="flex w-full flex-col gap-3 xl:flex-row xl:items-start">
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

          <div class={["grid min-w-0 w-full items-stretch", @content_class]}>
            {render_slot(@inner_block)}
          </div>
        </div>
      </section>
    </section>
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
