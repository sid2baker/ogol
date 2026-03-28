defmodule Ogol.HMIWeb.StudioIndexLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.Studio.Bundle

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> allow_upload(:bundle, accept: ~w(text/plain), max_entries: 1)
     |> assign(:page_title, "Studio")
     |> assign(
       :page_summary,
       "Source-native authoring surfaces for HMIs, simulator work, EtherCAT, topology, machines, and drivers."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :studio_home)
     |> assign(:bundle_app_id, "ogol_bundle")
     |> assign(:show_bundle_import, false)
     |> assign(:studio_feedback, nil)}
  end

  @impl true
  def handle_event("change_bundle_settings", %{"bundle" => params}, socket) do
    app_id =
      params
      |> Map.get("app_id", socket.assigns.bundle_app_id)
      |> normalize_bundle_app_id()

    {:noreply, assign(socket, :bundle_app_id, app_id)}
  end

  def handle_event("toggle_bundle_import", _params, socket) do
    show_bundle_import = not socket.assigns.show_bundle_import

    socket =
      if show_bundle_import do
        socket
      else
        clear_bundle_uploads(socket)
      end

    {:noreply, assign(socket, :show_bundle_import, show_bundle_import)}
  end

  def handle_event("import_bundle", _params, socket) do
    case consume_uploaded_entries(socket, :bundle, fn %{path: path}, _entry ->
           {:ok, File.read!(path)}
         end) do
      [] ->
        {:noreply,
         assign(
           socket,
           :studio_feedback,
           feedback(:error, "Open bundle failed", "Choose a `.ogol.ex` bundle file first.")
         )}

      [source | _] ->
        case Bundle.import_into_stores(source) do
          {:ok, bundle} ->
            case bundle_destination(bundle) do
              nil ->
                {:noreply,
                 socket
                 |> assign(:show_bundle_import, false)
                 |> assign(
                   :studio_feedback,
                   feedback(
                     :info,
                     "Bundle loaded",
                     "Imported #{length(bundle.artifacts)} artifact(s) from #{bundle.app_id}."
                   )
                 )}

              destination ->
                {:noreply,
                 socket
                 |> put_flash(
                   :info,
                   "Bundle loaded from #{bundle.app_id} with #{length(bundle.artifacts)} artifact(s)."
                 )
                 |> push_navigate(to: destination)}
            end

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :studio_feedback,
               feedback(
                 :error,
                 "Open bundle failed",
                 "Bundle import failed: #{inspect(reason)}"
               )
             )}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="grid gap-5 xl:grid-cols-[minmax(0,1.2fr)_minmax(0,0.8fr)]">
      <div class="space-y-5">
        <section class="app-panel px-5 py-5">
          <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
            <div class="max-w-3xl">
              <p class="app-kicker">Studio Contract</p>
              <h2 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
                Visual editors are projections over canonical source
              </h2>
              <p class="mt-3 text-base leading-7 text-[var(--app-text-muted)]">
                Save, diff, compile, and activate always operate on source. Visual editing is available only when the system can classify and preserve semantics confidently.
              </p>
            </div>

            <div class="grid gap-2 sm:grid-cols-2">
              <.state_chip title="Visual" detail="Full bidirectional editing" tone="good" />
              <.state_chip title="Partial" detail="Section-level fallback" tone="warn" />
              <.state_chip title="Source-only" detail="Source remains authoritative" tone="info" />
              <.state_chip title="Invalid" detail="Diagnostics, no activation" tone="danger" />
            </div>
          </div>
        </section>

        <section class="grid gap-4 md:grid-cols-2 2xl:grid-cols-5">
          <.artifact_card
            title="HMIs"
            summary="Template-first runtime surface authoring with compiled deployment and fixed viewport profiles."
            path={~p"/studio/hmis"}
            action="Open HMI Studio"
            state="active"
          />
          <.artifact_card
            title="Simulator"
            summary="Single Studio Cell for simulated ring authoring with explicit start/stop runtime control."
            path={~p"/studio/simulator"}
            action="Open Simulator Studio"
            state="active"
          />
          <.artifact_card
            title="EtherCAT"
            summary="Master configuration and live bus supervision for watching slaves, faults, and runtime state."
            path={~p"/studio/ethercat"}
            action="Open EtherCAT Studio"
            state="active"
          />
          <.artifact_card
            title="Topology"
            summary="Flat deployment authoring, dependency binding, signal/status/down observation."
            path={~p"/studio/topology"}
            action="Open Topology Studio"
            state="planned"
          />
          <.artifact_card
            title="Machines"
            summary="State graph, public interface, and dependency declarations over canonical source."
            path={~p"/studio/machines"}
            action="Open Machine Studio"
            state="planned"
          />
          <.artifact_card
            title="Drivers"
            summary="EtherCAT driver authoring on the same visual + source shell."
            path={~p"/studio/drivers"}
            action="Open Driver Studio"
            state="active"
          />
        </section>
      </div>

      <aside class="space-y-5">
        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Studio Bundle</p>
          <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
            Open or export one `.ogol.ex` bundle for the current Studio application. Bundle import parses and classifies source without executing it.
          </p>

          <form phx-change="change_bundle_settings" class="mt-4">
            <label class="space-y-2">
              <span class="app-field-label">Application Id</span>
              <input
                type="text"
                name="bundle[app_id]"
                value={@bundle_app_id}
                class="app-input w-full"
                autocomplete="off"
              />
            </label>
          </form>

          <div class="mt-4 flex flex-wrap gap-2">
            <.link href={bundle_download_path(assigns)} class="app-button">
              Export Bundle
            </.link>
            <button type="button" phx-click="toggle_bundle_import" class="app-button-secondary">
              {if @show_bundle_import, do: "Close Bundle", else: "Open Bundle"}
            </button>
          </div>

          <div :if={@studio_feedback} class={["mt-4 rounded-2xl px-4 py-4", feedback_classes(@studio_feedback.level)]}>
            <p class="font-semibold">{@studio_feedback.title}</p>
            <p class="mt-1 text-sm leading-6">{@studio_feedback.detail}</p>
          </div>

          <.bundle_import_panel :if={@show_bundle_import} uploads={@uploads} />
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Studio Pipeline</p>
          <ol class="mt-4 space-y-3">
            <.pipeline_step step="Load" detail="Source -> parse -> classify -> determine visual availability -> lower where supported." />
            <.pipeline_step step="Edit" detail="Visual edits lower back to source. Source edits re-parse and refresh diagnostics." />
            <.pipeline_step step="Save" detail="Only source drafts are persisted." />
            <.pipeline_step step="Compile" detail="Compile runs against source, not the visual model." />
            <.pipeline_step step="Activate / Deploy / Assign" detail="Machines activate compiled runtime artifacts; HMI surfaces deploy versions and assign them to panels." />
          </ol>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Invariants</p>
          <ul class="mt-4 space-y-3 text-sm leading-6 text-[var(--app-text-muted)]">
            <li>Source is the only persisted authority.</li>
            <li>Unsupported constructs fail closed into source-first editing.</li>
            <li>Visual save flows must never silently discard unsupported semantics.</li>
            <li>Parse, classification, validation, and compile stay separate in the UI.</li>
          </ul>
        </section>
      </aside>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:summary, :string, required: true)
  attr(:path, :string, required: true)
  attr(:action, :string, required: true)
  attr(:state, :string, required: true)

  def artifact_card(assigns) do
    ~H"""
    <article class="app-panel px-4 py-4">
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="app-kicker">{@title}</p>
          <h3 class="mt-1 text-xl font-semibold text-[var(--app-text)]">{@title}</h3>
        </div>
        <span class={["studio-state", studio_state_classes(@state)]}>{@state}</span>
      </div>
      <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">{@summary}</p>
      <.link navigate={@path} class="studio-link mt-4 inline-flex">
        {@action}
      </.link>
    </article>
    """
  end

  attr(:title, :string, required: true)
  attr(:detail, :string, required: true)
  attr(:tone, :string, required: true)

  def state_chip(assigns) do
    ~H"""
    <div class={["studio-state-card", state_chip_classes(@tone)]}>
      <p class="font-mono text-[11px] uppercase tracking-[0.22em]">{@title}</p>
      <p class="mt-1 text-sm font-semibold">{@detail}</p>
    </div>
    """
  end

  attr(:step, :string, required: true)
  attr(:detail, :string, required: true)

  def pipeline_step(assigns) do
    ~H"""
    <li class="border-l-4 border-[var(--app-border)] pl-3">
      <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">{@step}</p>
      <p class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">{@detail}</p>
    </li>
    """
  end

  defp studio_state_classes("active"),
    do: "border-[var(--app-good-border)] bg-[var(--app-good-surface)] text-[var(--app-good-text)]"

  defp studio_state_classes(_),
    do: "border-[var(--app-border)] bg-[var(--app-surface-alt)] text-[var(--app-text-muted)]"

  defp state_chip_classes("good"),
    do: "border-[var(--app-good-border)] bg-[var(--app-good-surface)] text-[var(--app-good-text)]"

  defp state_chip_classes("warn"),
    do: "border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] text-[var(--app-warn-text)]"

  defp state_chip_classes("danger"),
    do:
      "border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"

  defp state_chip_classes(_tone),
    do: "border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]"

  attr(:uploads, :map, required: true)

  defp bundle_import_panel(assigns) do
    ~H"""
    <form id="studio-bundle-import-form" phx-submit="import_bundle" class="mt-4 space-y-4">
      <div class="space-y-2">
        <span class="app-field-label">Bundle File</span>
        <.live_file_input upload={@uploads.bundle} class="app-input w-full" />
        <p class="text-sm leading-6 text-[var(--app-text-muted)]">
          Upload a saved `.ogol.ex` file. Import restores source-backed Studio artifacts and optional workspace hints.
        </p>
      </div>

      <div :if={@uploads.bundle.entries != []} class="space-y-2">
        <p class="app-kicker">Selected File</p>
        <div
          :for={entry <- @uploads.bundle.entries}
          class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-3"
        >
          <p class="text-sm font-semibold text-[var(--app-text)]">{entry.client_name}</p>
          <p class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">
            {entry.progress}% uploaded
          </p>
        </div>
      </div>

      <button type="submit" class="app-button">
        Load Bundle
      </button>
    </form>
    """
  end

  defp bundle_download_path(assigns) do
    query =
      %{
        app_id: assigns.bundle_app_id
      }
      |> URI.encode_query()

    "/studio/bundle/download?#{query}"
  end

  defp normalize_bundle_app_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "ogol_bundle"
      app_id -> app_id
    end
  end

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}

  defp feedback_classes(:info),
    do:
      "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]"

  defp feedback_classes(_level),
    do:
      "border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"

  defp clear_bundle_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.bundle.entries, socket, fn entry, acc ->
      try do
        cancel_upload(acc, :bundle, entry.ref)
      catch
        :exit, _ -> acc
      end
    end)
  end

  defp bundle_destination(bundle) do
    workspace = bundle.workspace || %{}

    case workspace[:open_artifact] || workspace["open_artifact"] do
      {:driver, id} -> ~p"/studio/drivers/#{id}"
      {"driver", id} -> ~p"/studio/drivers/#{id}"
      {:hmi_surface, id} -> ~p"/studio/hmis/#{id}"
      {"hmi_surface", id} -> ~p"/studio/hmis/#{id}"
      {:surface, id} -> ~p"/studio/hmis/#{id}"
      {"surface", id} -> ~p"/studio/hmis/#{id}"
      _ -> nil
    end
  end
end
