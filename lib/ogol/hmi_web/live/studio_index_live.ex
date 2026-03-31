defmodule Ogol.HMIWeb.StudioIndexLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMIWeb.StudioRevision
  alias Ogol.Studio.Bundle
  alias Ogol.Studio.Examples
  alias Ogol.Studio.RevisionStore
  alias Ogol.Studio.WorkspaceStore

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> allow_upload(:bundle, accept: ~w(text/plain), max_entries: 1)
     |> assign(:page_title, "Studio")
     |> assign(
       :page_summary,
       "Source-native authoring for bundles, examples, bring-up, HMIs, sequences, topology, machines, and hardware."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :studio_home)
     |> assign(:bundle_app_id, "ogol_bundle")
     |> assign(:show_bundle_import, false)
     |> assign(:pending_bundle_source, nil)
     |> assign(:examples, Examples.list())
     |> assign(:loaded_example_id, nil)
     |> assign(:pending_example_id, nil)
     |> assign(:studio_feedback, nil)
     |> assign(:deploy_topology_id, nil)
     |> assign(:deploy_topology_options, [])
     |> refresh_deploy_targets()}
  end

  @impl true
  def handle_event("change_bundle_settings", %{"bundle" => params}, socket) do
    app_id =
      params
      |> Map.get("app_id", socket.assigns.bundle_app_id)
      |> normalize_bundle_app_id()

    socket =
      socket
      |> assign(:bundle_app_id, app_id)
      |> assign(:deploy_topology_id, normalize_optional_id(params["topology_id"]))
      |> refresh_deploy_targets()

    {:noreply, socket}
  end

  def handle_event("toggle_bundle_import", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(:info, StudioRevision.readonly_title(), StudioRevision.readonly_message())
       )}
    else
      show_bundle_import = not socket.assigns.show_bundle_import

      socket =
        if show_bundle_import do
          socket
        else
          clear_bundle_uploads(socket)
        end

      {:noreply, assign(socket, :show_bundle_import, show_bundle_import)}
    end
  end

  def handle_event("deploy_revision", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(:info, StudioRevision.readonly_title(), StudioRevision.readonly_message())
       )}
    else
      case RevisionStore.deploy_current(
             app_id: socket.assigns.bundle_app_id,
             topology_id: socket.assigns.deploy_topology_id
           ) do
        {:ok, revision} ->
          {:noreply,
           socket
           |> refresh_deploy_targets()
           |> assign(
             :studio_feedback,
             deploy_feedback(revision)
           )}

        {:error, reason} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             deploy_failure_feedback(reason)
           )}
      end
    end
  end

  def handle_event("import_bundle", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(:info, StudioRevision.readonly_title(), StudioRevision.readonly_message())
       )}
    else
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
            {:ok, bundle, report} ->
              {:noreply,
               socket
               |> refresh_deploy_targets()
               |> assign(:show_bundle_import, false)
               |> assign(:pending_bundle_source, nil)
               |> assign(
                 :studio_feedback,
                 load_feedback(bundle, report)
               )}

            {:error, {:structural_mismatch, diff}} ->
              {:noreply,
               socket
               |> assign(:pending_bundle_source, source)
               |> assign(
                 :studio_feedback,
                 feedback(
                   :warning,
                   "Structural change detected",
                   structural_mismatch_message(diff)
                 )
               )}

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
  end

  def handle_event("force_import_bundle", _params, socket) do
    case socket.assigns.pending_bundle_source do
      nil ->
        {:noreply, socket}

      source ->
        case Bundle.import_into_stores(source, force: true) do
          {:ok, bundle, report} ->
            {:noreply,
             socket
             |> refresh_deploy_targets()
             |> assign(:show_bundle_import, false)
             |> assign(:pending_bundle_source, nil)
             |> assign(:studio_feedback, load_feedback(bundle, report))}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :studio_feedback,
               feedback(:error, "Force load failed", "Bundle load failed: #{inspect(reason)}")
             )}
        end
    end
  end

  def handle_event("load_example", %{"id" => id}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(:info, StudioRevision.readonly_title(), StudioRevision.readonly_message())
       )}
    else
      case Examples.import_into_stores(id) do
        {:ok, %{id: _example_id} = example, bundle, report} ->
          {:noreply,
           socket
           |> refresh_deploy_targets()
           |> assign(:loaded_example_id, example.id)
           |> assign(:pending_example_id, nil)
           |> assign(:studio_feedback, example_load_feedback(example, bundle, report))}

        {:error, {:structural_mismatch, diff}} ->
          {:noreply,
           socket
           |> assign(:pending_example_id, id)
           |> assign(
             :studio_feedback,
             feedback(
               :warning,
               "Structural change detected",
               structural_mismatch_message(diff)
             )
           )}

        {:error, :unknown_example} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(:error, "Load failed", "The requested example is not registered.")
           )}

        {:error, reason} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(:error, "Load failed", "Example import failed: #{inspect(reason)}")
           )}
      end
    end
  end

  def handle_event("force_load_example", %{"id" => id}, socket) do
    case Examples.import_into_stores(id, force: true) do
      {:ok, %{id: _example_id} = example, bundle, report} ->
        {:noreply,
         socket
         |> refresh_deploy_targets()
         |> assign(:loaded_example_id, example.id)
         |> assign(:pending_example_id, nil)
         |> assign(:studio_feedback, example_load_feedback(example, bundle, report))}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :studio_feedback,
           feedback(:error, "Force load failed", "Example import failed: #{inspect(reason)}")
         )}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, StudioRevision.apply_param(socket, params)}
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
            path={StudioRevision.path_with_revision(~p"/studio/hmis", @studio_selected_revision)}
            action="Open HMI Studio"
            state="active"
          />
          <.artifact_card
            title="Sequences"
            summary="Source-first orchestration over public machine skills, durable status, and topology-visible state."
            path={StudioRevision.path_with_revision(~p"/studio/sequences", @studio_selected_revision)}
            action="Open Sequence Studio"
            state="active"
          />
          <.artifact_card
            title="Topology"
            summary="Flat deployment authoring, dependency binding, signal/status/down observation."
            path={StudioRevision.path_with_revision(~p"/studio/topology", @studio_selected_revision)}
            action="Open Topology Studio"
            state="active"
          />
          <.artifact_card
            title="Machines"
            summary="State graph, public interface, and dependency declarations over canonical source."
            path={StudioRevision.path_with_revision(~p"/studio/machines", @studio_selected_revision)}
            action="Open Machine Studio"
            state="active"
          />
          <.artifact_card
            title="Hardware"
            summary="EtherCAT bring-up, saved hardware configs, and driver authoring from one hardware shell."
            path={StudioRevision.path_with_revision(~p"/studio/hardware", @studio_selected_revision)}
            action="Open Hardware Studio"
            state="active"
          />
        </section>

        <section class="app-panel px-5 py-5">
          <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
            <div class="max-w-3xl">
              <p class="app-kicker">Bring-up</p>
              <h2 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
                Start simulation and hardware work from the Studio hub
              </h2>
              <p class="mt-3 text-base leading-7 text-[var(--app-text-muted)]">
                Runtime bring-up is not a separate authoring system. Use these entry points to start simulator rehearsal or move into the hardware shell for EtherCAT startup and driver work.
              </p>
            </div>
          </div>

          <div class="mt-5 grid gap-4 md:grid-cols-2">
            <.artifact_card
              title="Simulator"
              summary="Draft-first simulated ring rehearsal with explicit start/stop runtime control."
              path={StudioRevision.path_with_revision(~p"/studio/simulator", @studio_selected_revision)}
              action="Open Simulator"
              state="active"
            />
            <.artifact_card
              title="Hardware Startup"
              summary="Bring up the EtherCAT master, inspect the bus, and switch into driver work from the hardware shell."
              path={StudioRevision.path_with_revision(~p"/studio/hardware", @studio_selected_revision)}
              action="Open Hardware Startup"
              state="active"
            />
          </div>
        </section>

        <section class="space-y-5">
          <section class="app-panel px-5 py-5">
            <p class="app-kicker">Examples</p>
            <h2 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
              Load checked-in revision bundles as the current draft
            </h2>
            <p class="mt-3 max-w-3xl text-base leading-7 text-[var(--app-text-muted)]">
              These examples use the same bundle import path as exported `.ogol.ex` revisions. There is no special example-only loader.
            </p>
          </section>

          <section class="grid gap-4">
            <article
              :for={example <- @examples}
              class="app-panel px-5 py-5"
              data-test={"example-#{example.id}"}
            >
              <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                <div class="min-w-0">
                  <p class="app-kicker">Revision Bundle Example</p>
                  <h3 class="mt-1 text-2xl font-semibold text-[var(--app-text)]">{example.title}</h3>
                  <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">{example.summary}</p>
                </div>

                <button
                  type="button"
                  phx-click="load_example"
                  phx-value-id={example.id}
                  class="app-button disabled:cursor-not-allowed disabled:opacity-60"
                  disabled={@studio_read_only?}
                  title={if(@studio_read_only?, do: StudioRevision.readonly_message())}
                  data-test={"load-example-#{example.id}"}
                >
                  Load Into Draft
                </button>
              </div>

              <div class="mt-4 grid gap-3 xl:grid-cols-2">
                <div class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
                  <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                    Includes
                  </p>
                  <p class="mt-2 text-sm leading-6 text-[var(--app-text)]">{example.artifact_summary}</p>
                </div>

                <div class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
                  <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                    Target Note
                  </p>
                  <p class="mt-2 text-sm leading-6 text-[var(--app-text)]">{example.target_note}</p>
                </div>
              </div>

              <div :if={@loaded_example_id == example.id} class="mt-4 flex flex-wrap gap-2">
                <.link
                  navigate={machine_studio_path(example, @studio_selected_revision)}
                  class="app-button-secondary"
                >
                  Open Machine Studio
                </.link>
                <.link
                  :if={example.topology_id}
                  navigate={
                    StudioRevision.path_with_revision(
                      "/studio/topology?topology=#{example.topology_id}",
                      @studio_selected_revision
                    )
                  }
                  class="app-button-secondary"
                >
                  Open Topology Studio
                </.link>
                <.link
                  :if={example.sequence_id}
                  navigate={
                    StudioRevision.path_with_revision(
                      "/studio/sequences/#{example.sequence_id}",
                      @studio_selected_revision
                    )
                  }
                  class="app-button-secondary"
                >
                  Open Sequence Studio
                </.link>
              </div>

              <div :if={@pending_example_id == example.id} class="mt-4">
                <button
                  type="button"
                  phx-click="force_load_example"
                  phx-value-id={example.id}
                  class="app-button"
                >
                  Force Load
                </button>
              </div>
            </article>
          </section>
        </section>
      </div>

      <aside class="space-y-5">
        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Studio Bundle</p>
          <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
            Open or export one `.ogol.ex` bundle for the current Studio application. The first load compiles source-backed cells into the current runtime. Later compatible loads refresh source and mark stale cells until you compile them explicitly.
          </p>

          <form phx-change="change_bundle_settings" class="mt-4">
            <div class="grid gap-4">
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

              <label class="space-y-2">
                <span class="app-field-label">Deploy Topology</span>
                <select
                  name="bundle[topology_id]"
                  class="app-input w-full"
                  value={@deploy_topology_id}
                >
                  <option :for={{label, id} <- @deploy_topology_options} value={id} selected={id == @deploy_topology_id}>
                    {label}
                  </option>
                </select>
              </label>
            </div>
          </form>

          <div class="mt-4 flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="deploy_revision"
              class="app-button disabled:cursor-not-allowed disabled:opacity-60"
              data-test="deploy-revision"
              disabled={@studio_read_only? or not deploy_ready?(assigns)}
            >
              Deploy Revision
            </button>
            <.link href={bundle_download_path(assigns)} class="app-button">
              Export Bundle
            </.link>
            <button
              type="button"
              phx-click="toggle_bundle_import"
              class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
              disabled={@studio_read_only?}
            >
              {if @show_bundle_import, do: "Close Bundle", else: "Open Bundle"}
            </button>
          </div>

          <div :if={@studio_feedback} class={["mt-4 rounded-2xl px-4 py-4", feedback_classes(@studio_feedback.level)]}>
            <p class="font-semibold">{@studio_feedback.title}</p>
            <p class="mt-1 text-sm leading-6">{@studio_feedback.detail}</p>

            <button
              :if={@pending_bundle_source}
              type="button"
              phx-click="force_import_bundle"
              class="app-button mt-3"
            >
              Force Load
            </button>
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
            <.pipeline_step step="Deploy" detail="Deploy snapshots the current workspace into a new revision, activates the selected hardware config, and starts the selected topology runtime." />
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
          Upload a saved `.ogol.ex` file. First load compiles source-backed cells into the current runtime. Compatible reloads refresh source and leave changed cells stale until recompiled.
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

  defp refresh_deploy_targets(socket) do
    topology_options = deploy_topology_options()
    topology_ids = Enum.map(topology_options, &elem(&1, 1))

    selected_topology_id =
      choose_selected_id(
        socket.assigns[:deploy_topology_id],
        topology_ids,
        default_topology_id(topology_ids)
      )

    socket
    |> assign(:deploy_topology_options, topology_options)
    |> assign(:deploy_topology_id, selected_topology_id)
  end

  defp deploy_topology_options do
    WorkspaceStore.list_topologies()
    |> Enum.map(fn draft ->
      {"#{humanize_id(draft.id)} (#{draft.id})", draft.id}
    end)
  end

  defp default_topology_id(topology_ids) when is_list(topology_ids) do
    default_id = WorkspaceStore.topology_default_id()

    if default_id in topology_ids do
      default_id
    else
      List.first(topology_ids)
    end
  end

  defp choose_selected_id(current_id, ids, fallback) when is_list(ids) do
    current_id = normalize_optional_id(current_id)

    cond do
      current_id in ids -> current_id
      fallback in ids -> fallback
      true -> nil
    end
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

  defp normalize_optional_id(nil), do: nil

  defp normalize_optional_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      id -> id
    end
  end

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}

  defp deploy_feedback(revision) do
    feedback(
      :info,
      "Revision deployed",
      "#{revision.id} is now active on topology #{revision.topology_id} using hardware config #{revision.hardware_config_id}. The workspace continues from that deployed revision baseline."
    )
  end

  defp deploy_failure_feedback({:unknown_topology, topology_id}) do
    feedback(
      :error,
      "Deploy failed",
      "Topology #{topology_id} is not present in the current workspace."
    )
  end

  defp deploy_failure_feedback(:no_topology_available) do
    feedback(:error, "Deploy failed", "Add a topology before deploying a runtime revision.")
  end

  defp deploy_failure_feedback(:no_hardware_config_available) do
    feedback(
      :error,
      "Deploy failed",
      "Add a hardware config before deploying a runtime revision."
    )
  end

  defp deploy_failure_feedback({:runtime_reset_blocked, %{modules: modules}}) do
    feedback(
      :warning,
      "Deploy blocked",
      "Old code is still in use for #{length(modules)} loaded module(s). Stop draining processes and retry the deploy."
    )
  end

  defp deploy_failure_feedback({:compile_failed, kind, id, diagnostics}) do
    feedback(
      :error,
      "Deploy failed",
      "Compile #{kind} #{id} before deploying: #{format_diagnostics(diagnostics)}"
    )
  end

  defp deploy_failure_feedback({:runtime_blocked, kind, id, reason}) do
    feedback(
      :error,
      "Deploy failed",
      "Compiled #{kind} #{id} is blocked in the runtime: #{inspect(reason)}"
    )
  end

  defp deploy_failure_feedback({:runtime_out_of_date, kind, id, _status}) do
    feedback(
      :error,
      "Deploy failed",
      "Compiled #{kind} #{id} did not load as the current runtime module."
    )
  end

  defp deploy_failure_feedback({:runtime_not_loaded, kind, id}) do
    feedback(
      :error,
      "Deploy failed",
      "Compiled #{kind} #{id} did not load into the runtime."
    )
  end

  defp deploy_failure_feedback(reason) do
    feedback(:error, "Deploy failed", "Runtime activation failed: #{inspect(reason)}")
  end

  defp format_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> List.first()
    |> case do
      nil -> "unknown diagnostic"
      detail when is_binary(detail) -> detail
      %{message: message} when is_binary(message) -> message
      detail -> inspect(detail)
    end
  end

  defp load_feedback(bundle, %{mode: :initial}) do
    feedback(
      :info,
      "Bundle loaded",
      "Loaded #{length(bundle.artifacts)} artifact(s) from #{bundle.app_id} revision #{bundle.revision} and compiled the source-backed cells into the current runtime."
    )
  end

  defp load_feedback(bundle, %{mode: :compatible_reload}) do
    feedback(
      :info,
      "Bundle refreshed",
      "Updated #{length(bundle.artifacts)} artifact(s) from #{bundle.app_id} revision #{bundle.revision}. Compatible source changes stay in the workspace and stale cells now need an explicit compile."
    )
  end

  defp load_feedback(bundle, %{mode: :forced_reload}) do
    feedback(
      :warning,
      "Bundle force loaded",
      "Replaced the loaded structure with #{length(bundle.artifacts)} artifact(s) from #{bundle.app_id} revision #{bundle.revision} and recompiled the source-backed cells."
    )
  end

  defp structural_mismatch_message(%{added: added, removed: removed, changed: changed}) do
    parts =
      [
        inventory_count_message("added", added),
        inventory_count_message("removed", removed),
        changed_module_message(changed)
      ]
      |> Enum.reject(&is_nil/1)

    "This bundle changes the loaded Studio structure (#{Enum.join(parts, ", ")}). Force load if you want to replace the currently loaded layout."
  end

  defp inventory_count_message(_label, []), do: nil
  defp inventory_count_message(label, items), do: "#{length(items)} #{label}"

  defp changed_module_message([]), do: nil
  defp changed_module_message(items), do: "#{length(items)} module change(s)"

  defp example_load_feedback(example, bundle, %{mode: :initial}) do
    feedback(
      :info,
      "Example loaded",
      "Loaded #{length(bundle.artifacts)} artifact(s) from the checked-in #{example.title} bundle and compiled the source-backed cells into the current runtime."
    )
  end

  defp example_load_feedback(example, bundle, %{mode: :compatible_reload}) do
    feedback(
      :info,
      "Example refreshed",
      "Updated #{length(bundle.artifacts)} artifact(s) from #{example.title}. Compatible source changes stay stale until you compile them explicitly."
    )
  end

  defp example_load_feedback(example, bundle, %{mode: :forced_reload}) do
    feedback(
      :warning,
      "Example force loaded",
      "Replaced the loaded structure with #{length(bundle.artifacts)} artifact(s) from #{example.title} and recompiled the source-backed cells."
    )
  end

  defp feedback_classes(:info),
    do:
      "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]"

  defp feedback_classes(:warning),
    do:
      "border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] text-[var(--app-warn-text)]"

  defp feedback_classes(_level),
    do:
      "border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"

  defp machine_studio_path(%{machine_id: machine_id}, selected_revision)
       when is_binary(machine_id) do
    StudioRevision.path_with_revision("/studio/machines/#{machine_id}", selected_revision)
  end

  defp machine_studio_path(_example, selected_revision) do
    StudioRevision.path_with_revision("/studio/machines", selected_revision)
  end

  defp deploy_ready?(assigns) do
    is_binary(assigns.deploy_topology_id)
  end

  defp humanize_id(id) do
    id
    |> to_string()
    |> String.replace("_", " ")
    |> String.trim()
    |> Phoenix.Naming.humanize()
  end

  defp clear_bundle_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.bundle.entries, socket, fn entry, acc ->
      try do
        cancel_upload(acc, :bundle, entry.ref)
      catch
        :exit, _ -> acc
      end
    end)
  end
end
