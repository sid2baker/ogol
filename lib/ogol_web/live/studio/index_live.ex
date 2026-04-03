defmodule OgolWeb.Studio.IndexLive do
  use OgolWeb, :live_view

  alias OgolWeb.Live.SessionSync
  alias OgolWeb.Studio.CellPath
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias Ogol.Session

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> allow_upload(:revision_file, accept: ~w(text/plain), max_entries: 1)
     |> assign(:page_title, "Studio")
     |> assign(
       :page_summary,
       "Source-native authoring for revisions, examples, bring-up, HMIs, sequences, topology, machines, and hardware."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :studio_home)
     |> assign(:revision_app_id, "ogol")
     |> assign(:show_revision_import, false)
     |> assign(:pending_revision_source, nil)
     |> assign(:examples, Session.list_examples())
     |> assign(:loaded_example_id, nil)
     |> assign(:pending_example_id, nil)
     |> assign(:studio_feedback, nil)
     |> assign(:workspace_topology_id, nil)
     |> StudioRevision.subscribe()
     |> refresh_deploy_targets()}
  end

  @impl true
  def handle_info({:operations, operations}, socket) do
    {:noreply,
     socket
     |> StudioRevision.apply_operations(operations)
     |> refresh_deploy_targets()}
  end

  def handle_info({:runtime_updated, _action, _reply}, socket) do
    {:noreply, refresh_deploy_targets(socket)}
  end

  @impl true
  def handle_event("change_revision_settings", %{"revision" => params}, socket) do
    app_id =
      params
      |> Map.get("app_id", socket.assigns.revision_app_id)
      |> normalize_revision_app_id()

    socket =
      socket
      |> assign(:revision_app_id, app_id)
      |> refresh_deploy_targets()

    {:noreply, socket}
  end

  def handle_event("toggle_revision_import", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(:info, StudioRevision.readonly_title(), StudioRevision.readonly_message())
       )}
    else
      show_revision_import = not socket.assigns.show_revision_import

      socket =
        if show_revision_import do
          socket
        else
          clear_revision_uploads(socket)
        end

      {:noreply, assign(socket, :show_revision_import, show_revision_import)}
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
      case Session.deploy_current_revision(app_id: socket.assigns.revision_app_id) do
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

  def handle_event("import_revision_file", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(:info, StudioRevision.readonly_title(), StudioRevision.readonly_message())
       )}
    else
      case consume_uploaded_entries(socket, :revision_file, fn %{path: path}, _entry ->
             {:ok, File.read!(path)}
           end) do
        [] ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :error,
               "Open revision failed",
               "Choose a `.ogol.ex` revision file first."
             )
           )}

        [source | _] ->
          case Session.load_revision_source(source) do
            {:ok, revision_file, report} ->
              {:noreply,
               socket
               |> SessionSync.refresh()
               |> refresh_deploy_targets()
               |> assign(:show_revision_import, false)
               |> assign(:pending_revision_source, nil)
               |> assign(
                 :studio_feedback,
                 load_feedback(revision_file, report)
               )}

            {:error, {:structural_mismatch, diff}} ->
              {:noreply,
               socket
               |> assign(:pending_revision_source, source)
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
                   "Open revision failed",
                   "Revision import failed: #{inspect(reason)}"
                 )
               )}
          end
      end
    end
  end

  def handle_event("force_import_revision_file", _params, socket) do
    case socket.assigns.pending_revision_source do
      nil ->
        {:noreply, socket}

      source ->
        case Session.load_revision_source(source, force: true) do
          {:ok, revision_file, report} ->
            {:noreply,
             socket
             |> SessionSync.refresh()
             |> refresh_deploy_targets()
             |> assign(:show_revision_import, false)
             |> assign(:pending_revision_source, nil)
             |> assign(:studio_feedback, load_feedback(revision_file, report))}

          {:error, reason} ->
            {:noreply,
             assign(
               socket,
               :studio_feedback,
               feedback(:error, "Force load failed", "Revision load failed: #{inspect(reason)}")
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
      case Session.load_example(id) do
        {:ok, %{id: _example_id} = example, revision_file, report} ->
          {:noreply,
           socket
           |> SessionSync.refresh()
           |> refresh_deploy_targets()
           |> assign(:loaded_example_id, example.id)
           |> assign(:pending_example_id, nil)
           |> assign(:studio_feedback, example_load_feedback(example, revision_file, report))}

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
    case Session.load_example(id, force: true) do
      {:ok, %{id: _example_id} = example, revision_file, report} ->
        {:noreply,
         socket
         |> SessionSync.refresh()
         |> refresh_deploy_targets()
         |> assign(:loaded_example_id, example.id)
         |> assign(:pending_example_id, nil)
         |> assign(:studio_feedback, example_load_feedback(example, revision_file, report))}

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
    {:noreply,
     socket
     |> StudioRevision.apply_param(params)
     |> refresh_deploy_targets()}
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
            summary="Adapter-first hardware authoring with EtherCAT config, slave mapping, and driver aliases inside one hardware cell."
            path={StudioRevision.path_with_revision(~p"/studio/hardware/ethercat", @studio_selected_revision)}
            action="Open Hardware Studio"
            state="active"
          />
        </section>

        <section class="app-panel px-5 py-5">
          <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
            <div class="max-w-3xl">
              <p class="app-kicker">Bring-up</p>
              <h2 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
                Manage simulation and bring hardware up from the Studio hub
              </h2>
              <p class="mt-3 text-base leading-7 text-[var(--app-text-muted)]">
                Simulator derives directly from the current EtherCAT config and is managed on its own page. Use Topology separately for master startup from the same workspace.
              </p>
            </div>
          </div>

          <div class="mt-5 grid gap-4 md:grid-cols-2">
            <.artifact_card
              title="Simulator"
              summary="Derived EtherCAT simulator page with explicit start and stop control over the current hardware config."
              path={StudioRevision.path_with_revision(~p"/studio/simulator", @studio_selected_revision)}
              action="Open Simulator"
              state="active"
            />
            <.artifact_card
              title="Hardware Startup"
              summary="Open the EtherCAT hardware config and edit slave driver mapping directly in the hardware workspace."
              path={StudioRevision.path_with_revision(~p"/studio/hardware/ethercat", @studio_selected_revision)}
              action="Open Hardware Startup"
              state="active"
            />
          </div>
        </section>

        <section class="space-y-5">
          <section class="app-panel px-5 py-5">
            <p class="app-kicker">Examples</p>
            <h2 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
              Load checked-in revisions into the current workspace
            </h2>
            <p class="mt-3 max-w-3xl text-base leading-7 text-[var(--app-text-muted)]">
              These examples use the same revision-file import path as exported `.ogol.ex` revisions. There is no special example-only loader.
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
                  <p class="app-kicker">Revision Example</p>
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
                  Load Into Workspace
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
                  navigate={machine_studio_path(example)}
                  class="app-button-secondary"
                >
                  Open Machine Studio
                </.link>
                <.link
                  :if={example.topology_id}
                  navigate={
                    CellPath.page_path(:topology, example.topology_id, :visual)
                  }
                  class="app-button-secondary"
                >
                  Open Topology Studio
                </.link>
                <.link
                  :if={example.sequence_id}
                  navigate={
                    CellPath.page_path(:sequence, example.sequence_id, :visual)
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
          <p class="app-kicker">Revision File</p>
          <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
            Open or export one `.ogol.ex` revision file for the current Studio application. The first load compiles source-backed cells into the current runtime. Later compatible loads refresh source and mark stale cells until you compile them explicitly.
          </p>

          <form phx-change="change_revision_settings" class="mt-4">
            <div class="grid gap-4">
              <label class="space-y-2">
                <span class="app-field-label">Application Id</span>
                <input
                  type="text"
                  name="revision[app_id]"
                  value={@revision_app_id}
                  class="app-input w-full"
                  autocomplete="off"
                />
              </label>

              <label class="space-y-2">
                <span class="app-field-label">Workspace Topology</span>
                <div class="app-input w-full py-2">
                  {deploy_topology_label(assigns)}
                </div>
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
            <.link href={revision_file_download_path(assigns)} class="app-button">
              Export Revision
            </.link>
            <button
              type="button"
              phx-click="toggle_revision_import"
              class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
              disabled={@studio_read_only?}
            >
              {if @show_revision_import, do: "Close Revision", else: "Open Revision"}
            </button>
          </div>

          <div :if={@studio_feedback} class={["mt-4 rounded-2xl px-4 py-4", feedback_classes(@studio_feedback.level)]}>
            <p class="font-semibold">{@studio_feedback.title}</p>
            <p class="mt-1 text-sm leading-6">{@studio_feedback.detail}</p>

            <button
              :if={@pending_revision_source}
              type="button"
              phx-click="force_import_revision_file"
              class="app-button mt-3"
            >
              Force Load
            </button>
          </div>

          <.revision_import_panel :if={@show_revision_import} uploads={@uploads} />
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

  defp revision_import_panel(assigns) do
    ~H"""
    <form
      id="studio-revision-import-form"
      phx-submit="import_revision_file"
      class="mt-4 space-y-4"
    >
      <div class="space-y-2">
        <span class="app-field-label">Revision File</span>
        <.live_file_input upload={@uploads.revision_file} class="app-input w-full" />
        <p class="text-sm leading-6 text-[var(--app-text-muted)]">
          Upload a saved `.ogol.ex` file. First load compiles source-backed cells into the current runtime. Compatible reloads refresh source and leave changed cells stale until recompiled.
        </p>
      </div>

      <div :if={@uploads.revision_file.entries != []} class="space-y-2">
        <p class="app-kicker">Selected File</p>
        <div
          :for={entry <- @uploads.revision_file.entries}
          class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-3"
        >
          <p class="text-sm font-semibold text-[var(--app-text)]">{entry.client_name}</p>
          <p class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">
            {entry.progress}% uploaded
          </p>
        </div>
      </div>

      <button type="submit" class="app-button">
        Load Revision
      </button>
    </form>
    """
  end

  defp revision_file_download_path(assigns) do
    query =
      %{
        app_id: assigns.revision_app_id
      }
      |> URI.encode_query()

    "/studio/revision_file/download?#{query}"
  end

  defp refresh_deploy_targets(socket) do
    socket
    |> assign(:workspace_topology_id, current_topology_artifact_id(socket))
  end

  defp current_topology_artifact_id(socket) do
    case SessionSync.list_entries(socket, :topology) do
      [%{id: id}] -> id
      [] -> nil
    end
  end

  defp deploy_topology_label(%{workspace_topology_id: id}) when is_binary(id),
    do: "#{humanize_id(id)} (#{id})"

  defp deploy_topology_label(_assigns), do: "No topology in the current workspace"

  defp normalize_revision_app_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "ogol"
      app_id -> app_id
    end
  end

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}

  defp deploy_feedback(revision) do
    feedback(
      :info,
      "Revision deployed",
      "#{revision.id} is now active for the workspace topology. The workspace continues from that deployed revision baseline."
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

  defp load_feedback(revision_file, %{mode: :initial}) do
    feedback(
      :info,
      "Revision loaded",
      "Loaded #{length(revision_file.artifacts)} artifact(s) from #{revision_file.app_id} revision #{revision_file.revision} and compiled the source-backed cells into the current runtime."
    )
  end

  defp load_feedback(revision_file, %{mode: :compatible_reload}) do
    feedback(
      :info,
      "Revision refreshed",
      "Updated #{length(revision_file.artifacts)} artifact(s) from #{revision_file.app_id} revision #{revision_file.revision}. Compatible source changes stay in the workspace and stale cells now need an explicit compile."
    )
  end

  defp load_feedback(revision_file, %{mode: :forced_reload}) do
    feedback(
      :warning,
      "Revision force loaded",
      "Replaced the loaded structure with #{length(revision_file.artifacts)} artifact(s) from #{revision_file.app_id} revision #{revision_file.revision} and recompiled the source-backed cells."
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

    "This revision changes the loaded Studio structure (#{Enum.join(parts, ", ")}). Force load if you want to replace the currently loaded layout."
  end

  defp inventory_count_message(_label, []), do: nil
  defp inventory_count_message(label, items), do: "#{length(items)} #{label}"

  defp changed_module_message([]), do: nil
  defp changed_module_message(items), do: "#{length(items)} module change(s)"

  defp example_load_feedback(example, revision_file, %{mode: :initial}) do
    feedback(
      :info,
      "Example loaded",
      "Loaded #{length(revision_file.artifacts)} artifact(s) from the checked-in #{example.title} revision and compiled the source-backed cells into the current runtime."
    )
  end

  defp example_load_feedback(example, revision_file, %{mode: :compatible_reload}) do
    feedback(
      :info,
      "Example refreshed",
      "Updated #{length(revision_file.artifacts)} artifact(s) from #{example.title}. Compatible source changes stay stale until you compile them explicitly."
    )
  end

  defp example_load_feedback(example, revision_file, %{mode: :forced_reload}) do
    feedback(
      :warning,
      "Example force loaded",
      "Replaced the loaded structure with #{length(revision_file.artifacts)} artifact(s) from #{example.title} and recompiled the source-backed cells."
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

  defp machine_studio_path(%{machine_id: machine_id}) when is_binary(machine_id),
    do: CellPath.page_path(:machine, machine_id, :config)

  defp machine_studio_path(_example), do: CellPath.section_path(:machine)

  defp deploy_ready?(assigns) do
    is_binary(assigns.workspace_topology_id)
  end

  defp humanize_id(id) do
    id
    |> to_string()
    |> String.replace("_", " ")
    |> String.trim()
    |> Phoenix.Naming.humanize()
  end

  defp clear_revision_uploads(socket) do
    Enum.reduce(socket.assigns.uploads.revision_file.entries, socket, fn entry, acc ->
      try do
        cancel_upload(acc, :revision_file, entry.ref)
      catch
        :exit, _ -> acc
      end
    end)
  end
end
