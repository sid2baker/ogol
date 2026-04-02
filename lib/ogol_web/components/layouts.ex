defmodule OgolWeb.Layouts do
  use OgolWeb, :html

  attr(:inner_content, :any, required: true)

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en" class="h-full bg-[var(--app-canvas)]">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Ogol HMI</title>
        <link phx-track-static rel="stylesheet" href={~p"/assets/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/app.js"}>
        </script>
      </head>
      <body class="h-full bg-[var(--app-canvas)] text-[var(--app-text)] antialiased">
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    assigns =
      assigns
      |> Map.put_new(:hmi_mode, :ops)
      |> Map.put_new(:hmi_nav, :runtime)
      |> Map.put_new(:hmi_subnav, nil)
      |> Map.put_new(:page_title, page_title_for(assigns[:hmi_mode], assigns[:hmi_nav]))
      |> Map.put_new(:page_summary, page_summary_for(assigns[:hmi_mode], assigns[:hmi_nav]))
      |> Map.put(:mode_items, mode_items(assigns[:hmi_mode] || :ops))
      |> Map.put(
        :section_items,
        section_items(assigns[:hmi_mode] || :ops, assigns[:hmi_nav] || :runtime)
      )
      |> Map.put(
        :subsection_items,
        subsection_items(
          assigns[:hmi_mode] || :ops,
          assigns[:hmi_nav] || :runtime,
          assigns[:hmi_subnav]
        )
      )

    ~H"""
    <div class="min-h-screen bg-[var(--app-canvas)] text-[var(--app-text)]">
      <header class="border-b border-[var(--app-border)] bg-[var(--app-shell)]">
        <div class="mx-auto max-w-[1680px] px-4 py-4 lg:px-6">
          <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
            <div class="min-w-0">
              <div class="flex items-center gap-3">
                <span class="h-2.5 w-2.5 bg-[var(--app-info-strong)]"></span>
                <p class="font-mono text-[11px] font-semibold uppercase tracking-[0.34em] text-[var(--app-text-dim)]">
                  Ogol Runtime
                </p>
              </div>
              <h1 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
                {@page_title}
              </h1>
              <p class="mt-2 max-w-4xl text-sm leading-6 text-[var(--app-text-muted)]">
                {@page_summary}
              </p>
            </div>

            <div class="flex flex-col gap-3 xl:items-end">
              <div class="flex flex-wrap items-end gap-3 xl:justify-end">
                <div class="inline-flex rounded-md border border-[var(--app-border)] bg-[var(--app-surface-alt)] p-1">
                  <.link
                    :for={item <- @mode_items}
                    navigate={item.path}
                    class={mode_link_classes(item.current?)}
                    aria-current={if(item.current?, do: "page", else: nil)}
                  >
                    {item.label}
                  </.link>
                </div>
              </div>
              <div class="flex flex-wrap gap-2">
                <.link
                  :for={item <- @section_items}
                  navigate={item.path}
                  class={section_link_classes(item.current?)}
                  aria-current={if(item.current?, do: "page", else: nil)}
                >
                  {item.label}
                </.link>
              </div>
              <div :if={@subsection_items != []} class="flex flex-wrap gap-2">
                <.link
                  :for={item <- @subsection_items}
                  navigate={item.path}
                  class={subsection_link_classes(item.current?)}
                  aria-current={if(item.current?, do: "page", else: nil)}
                >
                  {item.label}
                </.link>
              </div>
            </div>
          </div>
        </div>
      </header>

      <main class="mx-auto max-w-[1680px] px-4 py-5 lg:px-6">
        {@inner_content}
      </main>
    </div>
    """
  end

  def cell(assigns) do
    ~H"""
    {@inner_content}
    """
  end

  def surface(assigns) do
    assigns =
      assigns
      |> Map.put_new(:surface_title, "Runtime Surface")
      |> Map.put_new(:surface_summary, nil)
      |> Map.put_new(:surface_role, nil)
      |> Map.put_new(:surface_panel, nil)
      |> Map.put_new(:surface_version, nil)
      |> Map.put_new(:surface_viewport, nil)
      |> Map.put_new(:surface_screen, nil)

    ~H"""
    <div class="h-screen overflow-hidden bg-[var(--app-canvas)] text-[var(--app-text)]">
      <div class="flex h-screen flex-col">
        <header class="border-b border-[var(--app-border)] bg-[var(--app-shell)] px-4 py-4 lg:px-6">
          <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-3">
                <span class="h-2.5 w-2.5 bg-[var(--app-danger-text)]"></span>
                <p class="font-mono text-[11px] font-semibold uppercase tracking-[0.34em] text-[var(--app-text-dim)]">
                  Ogol Runtime Surface
                </p>
              </div>
              <h1 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
                {@surface_title}
              </h1>
              <p :if={@surface_summary} class="mt-2 max-w-4xl text-sm leading-6 text-[var(--app-text-muted)]">
                {@surface_summary}
              </p>
            </div>

            <div class="flex flex-wrap gap-2 xl:justify-end">
              <.surface_chip :if={@surface_role} label="Role" value={@surface_role} />
              <.surface_chip :if={@surface_panel} label="Panel" value={@surface_panel} />
              <.surface_chip
                :if={@surface_screen}
                label="Screen"
                value={@surface_screen.id || @surface_screen}
              />
              <.surface_chip :if={@surface_viewport} label="Viewport" value={@surface_viewport} />
              <.surface_chip :if={@surface_version} label="Version" value={@surface_version} />
            </div>
          </div>
        </header>

        <main class="flex-1 overflow-hidden px-4 py-4 lg:px-6">
          <div class="h-full overflow-hidden">
            {@inner_content}
          </div>
        </main>
      </div>
    </div>
    """
  end

  defp mode_items(:studio) do
    [
      %{label: "Operations", path: "/ops", current?: false},
      %{label: "Studio", path: "/studio", current?: true}
    ]
  end

  defp mode_items(_mode) do
    [
      %{label: "Operations", path: "/ops", current?: true},
      %{label: "Studio", path: "/studio", current?: false}
    ]
  end

  defp section_items(:studio, current) do
    [
      %{
        label: "Home",
        path: "/studio",
        current?: current in [:studio_home, :simulator]
      },
      %{
        label: "HMIs",
        path: "/studio/hmis",
        current?: current == :hmis
      },
      %{
        label: "Sequences",
        path: "/studio/sequences",
        current?: current == :sequences
      },
      %{
        label: "Topology",
        path: "/studio/topology",
        current?: current == :topology
      },
      %{
        label: "Machines",
        path: "/studio/machines",
        current?: current == :machines
      },
      %{
        label: "Hardware",
        path: "/studio/hardware",
        current?: current == :hardware
      }
    ]
  end

  defp section_items(_mode, current) do
    [
      %{label: "Runtime", path: "/ops", current?: current == :runtime},
      %{label: "Surfaces", path: "/ops/hmis", current?: current == :surfaces}
    ]
  end

  defp subsection_items(:studio, :hardware, current) do
    [
      %{
        label: "EtherCAT",
        path: "/studio/hardware/ethercat",
        current?: current in [nil, :ethercat]
      }
    ]
  end

  defp subsection_items(_mode, _current, _subnav), do: []

  defp page_title_for(:studio, :hmis), do: "HMI Studio"
  defp page_title_for(:studio, :simulator), do: "Simulator Studio"
  defp page_title_for(:studio, :hardware), do: "Hardware Studio"
  defp page_title_for(:studio, :topology), do: "Topology Studio"
  defp page_title_for(:studio, :sequences), do: "Sequence Studio"
  defp page_title_for(:studio, :machines), do: "Machine Studio"
  defp page_title_for(:studio, _), do: "Studio"
  defp page_title_for(:ops, :surfaces), do: "Runtime Surfaces"
  defp page_title_for(_mode, _nav), do: "Operations"

  defp page_summary_for(:studio, :hmis) do
    "Source-defined runtime surface authoring with template-first, viewport-bound operator panels."
  end

  defp page_summary_for(:studio, :simulator) do
    "Draft-first simulator authoring with one Studio Cell for generated source and explicit start/stop runtime control."
  end

  defp page_summary_for(:studio, :hardware) do
    "Adapter-first hardware authoring over canonical generated configs, with EtherCAT driver mapping edited inside the EtherCAT cell."
  end

  defp page_summary_for(:studio, :sequences) do
    "Source-first orchestration authoring over public machine skills, durable status, and topology-visible state."
  end

  defp page_summary_for(:studio, _nav) do
    "Visual and source authoring surfaces built over canonical Ogol artifacts."
  end

  defp page_summary_for(:ops, :surfaces),
    do: "Supervisor and fallback launcher for compiled operator surfaces."

  defp page_summary_for(_mode, _nav),
    do: "Triage-first runtime supervision with high-contrast operational surfaces."

  defp mode_link_classes(true) do
    "inline-flex items-center rounded-sm bg-[var(--app-info-strong)] px-4 py-2 font-mono text-[11px] font-semibold uppercase tracking-[0.22em] text-[var(--app-shell)]"
  end

  defp mode_link_classes(false) do
    "inline-flex items-center rounded-sm px-4 py-2 font-mono text-[11px] font-semibold uppercase tracking-[0.22em] text-[var(--app-text-muted)] transition hover:bg-[var(--app-surface-strong)] hover:text-[var(--app-text)]"
  end

  defp section_link_classes(true) do
    "inline-flex items-center border border-[var(--app-border-strong)] bg-[var(--app-surface-strong)] px-3 py-2 font-mono text-[11px] font-semibold uppercase tracking-[0.22em] text-[var(--app-text)]"
  end

  defp section_link_classes(false) do
    "inline-flex items-center border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-2 font-mono text-[11px] font-semibold uppercase tracking-[0.22em] text-[var(--app-text-muted)] transition hover:border-[var(--app-border-strong)] hover:text-[var(--app-text)]"
  end

  defp subsection_link_classes(true) do
    "inline-flex items-center border border-[var(--app-border-strong)] bg-[var(--app-shell)] px-3 py-1.5 font-mono text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--app-text)]"
  end

  defp subsection_link_classes(false) do
    "inline-flex items-center border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-1.5 font-mono text-[10px] font-semibold uppercase tracking-[0.22em] text-[var(--app-text-dim)] transition hover:border-[var(--app-border-strong)] hover:text-[var(--app-text)]"
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp surface_chip(assigns) do
    ~H"""
    <div class="border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2">
      <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">{@label}</p>
      <p class="mt-1 font-mono text-[11px] uppercase tracking-[0.18em] text-[var(--app-text)]">{@value}</p>
    </div>
    """
  end
end
