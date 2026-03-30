defmodule Ogol.HMIWeb.StudioExamplesLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMIWeb.StudioRevision
  alias Ogol.Studio.Examples

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Studio Examples")
     |> assign(
       :page_summary,
       "Checked-in revision bundles that load through the same Studio open-bundle path as exported `.ogol.ex` bundles."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :examples)
     |> assign(:examples, Examples.list())
     |> assign(:loaded_example_id, nil)
     |> assign(:studio_feedback, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, StudioRevision.apply_param(socket, params)}
  end

  @impl true
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
        {:ok, %{id: _example_id} = example, bundle} ->
          {:noreply,
           socket
           |> assign(:loaded_example_id, example.id)
           |> assign(
             :studio_feedback,
             feedback(
               :info,
               "Example loaded",
               "Loaded #{length(bundle.artifacts)} artifact(s) from the checked-in #{example.title} bundle as the current draft bundle."
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

  @impl true
  def render(assigns) do
    ~H"""
    <section class="grid gap-5 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]">
      <div class="space-y-5">
        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Examples</p>
          <h2 class="mt-2 text-3xl font-semibold tracking-tight text-[var(--app-text)]">
            Load checked-in revision bundles as the current draft
          </h2>
          <p class="mt-3 max-w-3xl text-base leading-7 text-[var(--app-text-muted)]">
            These examples do not use a special loader. Each card opens a saved `.ogol.ex` bundle through the same Studio bundle parser and draft replacement path as a normal exported revision.
          </p>

          <div :if={@studio_feedback} class={["mt-4 rounded-2xl px-4 py-4", feedback_classes(@studio_feedback.level)]}>
            <p class="font-semibold">{@studio_feedback.title}</p>
            <p class="mt-1 text-sm leading-6">{@studio_feedback.detail}</p>
          </div>
        </section>

        <section class="grid gap-4">
          <article :for={example <- @examples} class="app-panel px-5 py-5" data-test={"example-#{example.id}"}>
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
                :if={example.machine_id}
                navigate={StudioRevision.path_with_revision("/studio/machines/#{example.machine_id}", @studio_selected_revision)}
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
            </div>
          </article>
        </section>
      </div>

      <aside class="space-y-5">
        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Flow</p>
          <ol class="mt-4 space-y-3 text-sm leading-6 text-[var(--app-text-muted)]">
            <li>1. Load the example bundle as the current draft bundle.</li>
            <li>2. Open Machine Studio or Topology Studio to inspect or edit the imported source.</li>
            <li>3. Configure the target separately in Simulator and EtherCAT Studio.</li>
            <li>4. Build/apply the machine and start the topology when the target matches the bundle’s endpoint contract.</li>
          </ol>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Boundary</p>
          <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
            Examples are revision bundles, not target snapshots. They carry source-backed app artifacts only. Simulator configuration, EtherCAT configuration, and live runtime state stay outside the bundle on purpose.
          </p>
        </section>
      </aside>
    </section>
    """
  end

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}

  defp feedback_classes(:info),
    do:
      "border border-[var(--app-info-border)] bg-[var(--app-info-surface)] text-[var(--app-info-text)]"

  defp feedback_classes(_level),
    do:
      "border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] text-[var(--app-danger-text)]"
end
