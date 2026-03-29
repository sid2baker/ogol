defmodule Ogol.HMIWeb.Layouts do
  use Ogol.HMIWeb, :html

  alias Ogol.HMIWeb.StudioRevision
  alias Ogol.Studio.RevisionStore

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
      |> Map.put_new(:studio_selected_revision, nil)
      |> Map.put_new(:studio_selected_revision_bundle, nil)
      |> Map.put_new(:page_title, page_title_for(assigns[:hmi_mode], assigns[:hmi_nav]))
      |> Map.put_new(:page_summary, page_summary_for(assigns[:hmi_mode], assigns[:hmi_nav]))
      |> Map.put(
        :mode_items,
        mode_items(assigns[:hmi_mode] || :ops, assigns[:studio_selected_revision])
      )
      |> Map.put(
        :studio_revision_items,
        studio_revision_items(
          assigns[:hmi_mode] || :ops,
          assigns[:studio_selected_revision]
        )
      )
      |> Map.put(
        :section_items,
        section_items(
          assigns[:hmi_mode] || :ops,
          assigns[:hmi_nav] || :runtime,
          assigns[:studio_selected_revision]
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

                <div
                  :if={@studio_revision_items != []}
                  class="min-w-[10rem] border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-2"
                >
                  <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                    Revision
                  </p>
                  <form method="get">
                    <select
                      name="revision"
                      class="mt-2 w-full border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-2 font-mono text-[11px] uppercase tracking-[0.16em] text-[var(--app-text)]"
                      data-test="studio-revision-selector"
                      disabled={length(@studio_revision_items) <= 1}
                      onchange="this.form.requestSubmit()"
                    >
                      <option
                        :for={item <- @studio_revision_items}
                        value={item.id}
                        selected={item.current?}
                      >
                        {item.label}
                      </option>
                    </select>
                  </form>
                  <p
                    :if={@studio_selected_revision}
                    class="mt-2 text-[11px] leading-5 text-[var(--app-text-muted)]"
                  >
                    Saved revisions are read-only. Switch back to Draft to edit.
                  </p>
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

  defp mode_items(:studio, selected_revision) do
    [
      %{label: "Operations", path: "/ops", current?: false},
      %{
        label: "Studio",
        path: StudioRevision.path_with_revision("/studio", selected_revision),
        current?: true
      }
    ]
  end

  defp mode_items(_mode, _selected_revision) do
    [
      %{label: "Operations", path: "/ops", current?: true},
      %{label: "Studio", path: "/studio", current?: false}
    ]
  end

  defp studio_revision_items(:studio, selected_revision) do
    [
      %{id: "", label: "Draft", current?: is_nil(selected_revision)}
      | Enum.map(RevisionStore.list_revisions(), fn revision ->
          %{
            id: revision.id,
            label: revision.id,
            current?: revision.id == selected_revision
          }
        end)
    ]
  end

  defp studio_revision_items(_mode, _selected_revision), do: []

  defp section_items(:studio, current, selected_revision) do
    [
      %{
        label: "Home",
        path: StudioRevision.path_with_revision("/studio", selected_revision),
        current?: current == :studio_home
      },
      %{
        label: "HMIs",
        path: StudioRevision.path_with_revision("/studio/hmis", selected_revision),
        current?: current == :hmis
      },
      %{
        label: "Simulator",
        path: StudioRevision.path_with_revision("/studio/simulator", selected_revision),
        current?: current == :simulator
      },
      %{
        label: "EtherCAT",
        path: StudioRevision.path_with_revision("/studio/ethercat", selected_revision),
        current?: current == :ethercat
      },
      %{
        label: "Topology",
        path: StudioRevision.path_with_revision("/studio/topology", selected_revision),
        current?: current == :topology
      },
      %{
        label: "Machines",
        path: StudioRevision.path_with_revision("/studio/machines", selected_revision),
        current?: current == :machines
      },
      %{
        label: "Drivers",
        path: StudioRevision.path_with_revision("/studio/drivers", selected_revision),
        current?: current == :drivers
      }
    ]
  end

  defp section_items(_mode, current, _selected_revision) do
    [
      %{label: "Runtime", path: "/ops", current?: current == :runtime},
      %{label: "Surfaces", path: "/ops/hmis", current?: current == :surfaces}
    ]
  end

  defp page_title_for(:studio, :hmis), do: "HMI Studio"
  defp page_title_for(:studio, :simulator), do: "Simulator Studio"
  defp page_title_for(:studio, :ethercat), do: "EtherCAT Studio"
  defp page_title_for(:studio, :hardware), do: "EtherCAT Studio"
  defp page_title_for(:studio, :topology), do: "Topology Studio"
  defp page_title_for(:studio, :machines), do: "Machine Studio"
  defp page_title_for(:studio, :drivers), do: "Driver Studio"
  defp page_title_for(:studio, _), do: "Studio"
  defp page_title_for(:ops, :surfaces), do: "Runtime Surfaces"
  defp page_title_for(_mode, _nav), do: "Operations"

  defp page_summary_for(:studio, :hmis) do
    "Source-defined runtime surface authoring with template-first, viewport-bound operator panels."
  end

  defp page_summary_for(:studio, :simulator) do
    "Draft-first simulator authoring with one Studio Cell for generated source and explicit start/stop runtime control."
  end

  defp page_summary_for(:studio, :ethercat) do
    "Master configuration and live EtherCAT bus supervision over the same source-native Studio shell."
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
