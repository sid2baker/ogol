defmodule Ogol.HMIWeb.DriverStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.Studio.Build
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore
  alias Ogol.Studio.DriverParser
  alias Ogol.Studio.Modules

  @editor_modes [:visual, :source]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Driver Studio")
     |> assign(
       :page_summary,
       "Generate thin EtherCAT driver modules from a constrained model, build them without loading, and apply them safely under BEAM old-code rules."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :drivers)
     |> assign(:editor_modes, @editor_modes)
     |> assign(:editor_mode, :visual)
     |> assign(:studio_feedback, nil)
     |> load_driver(DriverDraftStore.default_id())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_driver(socket, params["driver_id"] || DriverDraftStore.default_id())}
  end

  @impl true
  def handle_event("set_editor_mode", %{"mode" => mode}, socket) do
    mode =
      mode
      |> String.to_existing_atom()
      |> then(fn mode -> if mode in @editor_modes, do: mode, else: :visual end)

    {:noreply, assign(socket, :editor_mode, mode)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("open_driver", %{"artifact" => %{"id" => id}}, socket) do
    id =
      id
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if id == "" do
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(:error, "Missing id", "Choose or enter a driver id to open a draft.")
       )}
    else
      {:noreply, push_patch(socket, to: ~p"/studio/drivers/#{id}")}
    end
  end

  def handle_event("change_visual", %{"driver" => params}, socket) do
    visual_form = normalize_visual_form(params, socket.assigns.visual_form)

    case DriverDefinition.cast_model(visual_form) do
      {:ok, model} ->
        source =
          DriverDefinition.to_source(DriverDefinition.module_from_name!(model.module_name), model)

        {:noreply,
         socket
         |> assign(:visual_form, visual_form)
         |> assign(:driver_model, model)
         |> assign(:draft_source, source)
         |> assign(:sync_state, :synced)
         |> assign(:sync_diagnostics, [])
         |> assign(:validation_errors, [])
         |> assign(:dirty?, true)
         |> assign(:studio_feedback, nil)}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:visual_form, visual_form)
         |> assign(:validation_errors, [error])
         |> assign(:studio_feedback, nil)}
    end
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    {socket, sync_state} =
      case DriverDefinition.from_source(source) do
        {:ok, model} ->
          {socket
           |> assign(:driver_model, model)
           |> assign(:visual_form, DriverDefinition.form_from_model(model))
           |> assign(:sync_diagnostics, [])
           |> assign(:validation_errors, []), :synced}

        {:partial, model, diagnostics} ->
          {socket
           |> assign(:driver_model, model)
           |> assign(:visual_form, DriverDefinition.form_from_model(model))
           |> assign(:sync_diagnostics, diagnostics)
           |> assign(:validation_errors, []), :partial}

        :unsupported ->
          {socket
           |> assign(
             :sync_diagnostics,
             ["Current source can no longer be represented by the visual editor."]
           )
           |> assign(:editor_mode, :source), :unsupported}
      end

    {:noreply,
     socket
     |> assign(:draft_source, source)
     |> assign(:sync_state, sync_state)
     |> assign(:dirty?, true)
     |> assign(:studio_feedback, nil)}
  end

  def handle_event("save_draft", _params, socket) do
    draft =
      DriverDraftStore.save_source(
        socket.assigns.driver_id,
        socket.assigns.draft_source,
        socket.assigns.driver_model,
        socket.assigns.sync_state,
        socket.assigns.sync_diagnostics
      )

    {:noreply,
     socket
     |> assign(:driver_draft, draft)
     |> assign(:dirty?, false)
     |> assign(
       :studio_feedback,
       feedback(:ok, "Draft saved", "Source draft persisted without building or applying.")
     )}
  end

  def handle_event("build_driver", _params, socket) do
    with {:ok, module} <- DriverParser.module_from_source(socket.assigns.draft_source),
         {:ok, artifact} <-
           Build.build(socket.assigns.driver_id, module, socket.assigns.draft_source) do
      draft =
        DriverDraftStore.record_build(socket.assigns.driver_id, artifact, artifact.diagnostics)

      {:noreply,
       socket
       |> assign(:driver_draft, draft)
       |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
       |> assign(
         :studio_feedback,
         feedback(
           :ok,
           "Build complete",
           "BEAM artifact prepared without loading it into runtime."
         )
       )}
    else
      {:error, %{diagnostics: diagnostics}} ->
        draft = DriverDraftStore.record_build(socket.assigns.driver_id, nil, diagnostics)

        {:noreply,
         socket
         |> assign(:driver_draft, draft)
         |> assign(
           :studio_feedback,
           feedback(
             :error,
             "Build failed",
             "Resolve compile diagnostics before applying this driver."
           )
         )}

      {:error, :module_not_found} ->
        {:noreply,
         assign(
           socket,
           :studio_feedback,
           feedback(
             :error,
             "Build failed",
             "Source must define one driver module before it can be built."
           )
         )}
    end
  end

  def handle_event("apply_driver", _params, socket) do
    case socket.assigns.driver_draft.build_artifact do
      nil ->
        {:noreply,
         assign(
           socket,
           :studio_feedback,
           feedback(:error, "Apply blocked", "Build a valid artifact before applying it.")
         )}

      artifact ->
        case Modules.apply(socket.assigns.driver_id, artifact) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
             |> assign(
               :studio_feedback,
               feedback(
                 :ok,
                 "Applied",
                 "The generated driver is now the active module for this logical id."
               )
             )}

          {:blocked, %{pids: pids}} ->
            {:noreply,
             socket
             |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
             |> assign(
               :studio_feedback,
               feedback(
                 :warn,
                 "Apply blocked",
                 "Old code is still draining in #{length(pids)} process(es). Retry once they leave the previous module."
               )
             )}

          {:error, {:module_mismatch, expected, actual}} ->
            {:noreply,
             socket
             |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
             |> assign(
               :studio_feedback,
               feedback(
                 :error,
                 "Apply blocked",
                 "Logical id #{socket.assigns.driver_id} is already bound to #{inspect(expected)} and cannot switch to #{inspect(actual)} in latest-only mode."
               )
             )}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
             |> assign(
               :studio_feedback,
               feedback(
                 :error,
                 "Apply failed",
                 "Runtime rejected the built artifact: #{inspect(reason)}"
               )
             )}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="grid gap-4 xl:grid-cols-[minmax(0,1.2fr)_22rem]">
      <div class="space-y-4">
        <section class="app-panel px-5 py-5">
          <div class="flex flex-col gap-4 2xl:flex-row 2xl:items-start 2xl:justify-between">
            <div class="max-w-4xl">
              <p class="app-kicker">Generated Module Artifact</p>
              <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
                {@driver_model && @driver_model.label || "Driver Studio"}
              </h2>
              <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                Model -> source -> artifact -> apply. Source stays authoritative. Apply is latest-only but blocks safely if old code still drains.
              </p>
            </div>

            <div class="flex flex-wrap gap-2">
              <button
                :for={mode <- @editor_modes}
                type="button"
                phx-click="set_editor_mode"
                phx-value-mode={mode}
                class={mode_button_classes(@editor_mode == mode)}
              >
                {mode_label(mode)}
              </button>
              <span class={sync_badge_classes(@sync_state)}>
                {sync_label(@sync_state)}
              </span>
            </div>
          </div>

          <form phx-submit="open_driver" class="mt-5 grid gap-3 md:grid-cols-[minmax(0,1fr)_auto]">
            <label class="space-y-2">
              <span class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                Artifact Id
              </span>
              <input
                type="text"
                name="artifact[id]"
                value={@driver_id}
                class="app-input w-full"
                autocomplete="off"
              />
            </label>
            <button type="submit" class="app-button self-end">
              Open Draft
            </button>
          </form>

          <div class="mt-4 flex flex-wrap gap-2">
            <.link
              :for={draft <- @driver_library}
              navigate={~p"/studio/drivers/#{draft.id}"}
              class={artifact_link_classes(draft.id == @driver_id)}
            >
              {draft.id}
            </.link>
          </div>

          <div :if={@studio_feedback} class={feedback_classes(@studio_feedback.level)}>
            <p class="font-semibold">{@studio_feedback.title}</p>
            <p class="mt-1 text-sm leading-6">{@studio_feedback.detail}</p>
          </div>
        </section>

        <section class="app-panel px-5 py-5">
          <div class="flex items-center justify-between gap-3">
            <div>
              <p class="app-kicker">{mode_label(@editor_mode)}</p>
              <h3 class="mt-1 text-xl font-semibold text-[var(--app-text)]">
                <%= if @editor_mode == :visual, do: "Constrained Driver Model", else: "Canonical Source" %>
              </h3>
            </div>
            <div class="flex flex-wrap gap-2">
              <button type="button" phx-click="save_draft" class="app-button-secondary">Save Draft</button>
              <button type="button" phx-click="build_driver" class="app-button-secondary">Build</button>
              <button type="button" phx-click="apply_driver" class="app-button">Apply</button>
            </div>
          </div>

          <div
            :if={@sync_state == :unsupported}
            class="mt-5 rounded-2xl border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-4 py-4 text-sm leading-6 text-[var(--app-danger-text)]"
          >
            <p class="font-semibold">Visual editor unavailable</p>
            <p class="mt-2">
              Current source can no longer be represented by the visual editor. Source editing remains authoritative until the driver returns to a supported shape.
            </p>
          </div>

          <div :if={@editor_mode == :visual} class="mt-5">
            <%= if @sync_state == :unsupported do %>
              <div class="app-panel-muted px-4 py-4">
                <p class="font-semibold text-[var(--app-warn-text)]">Visual editor unavailable</p>
                <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                  Current source can’t be represented safely. Source editing remains authoritative until the driver returns to a supported shape.
                </p>
              </div>
            <% else %>
              <form phx-change="change_visual" class="grid gap-4 md:grid-cols-2">
                <label class="space-y-2">
                  <span class="app-field-label">Logical Id</span>
                  <input type="text" name="driver[id]" value={@visual_form["id"]} class="app-input w-full" readonly />
                </label>
                <label class="space-y-2">
                  <span class="app-field-label">Module</span>
                  <input type="text" name="driver[module_name]" value={@visual_form["module_name"]} class="app-input w-full" />
                </label>
                <label class="space-y-2 md:col-span-2">
                  <span class="app-field-label">Label</span>
                  <input type="text" name="driver[label]" value={@visual_form["label"]} class="app-input w-full" />
                </label>
                <label class="space-y-2">
                  <span class="app-field-label">Device Kind</span>
                  <select name="driver[device_kind]" class="app-input w-full">
                    <option value="digital_input" selected={@visual_form["device_kind"] == "digital_input"}>digital_input</option>
                    <option value="digital_output" selected={@visual_form["device_kind"] == "digital_output"}>digital_output</option>
                  </select>
                </label>
                <label class="space-y-2">
                  <span class="app-field-label">Channel Count</span>
                  <input type="number" min="1" max="32" name="driver[channel_count]" value={@visual_form["channel_count"]} class="app-input w-full" />
                </label>
                <label class="space-y-2">
                  <span class="app-field-label">Vendor Id</span>
                  <input type="text" name="driver[vendor_id]" value={@visual_form["vendor_id"]} class="app-input w-full" />
                </label>
                <label class="space-y-2">
                  <span class="app-field-label">Product Code</span>
                  <input type="text" name="driver[product_code]" value={@visual_form["product_code"]} class="app-input w-full" />
                </label>
                <label class="space-y-2">
                  <span class="app-field-label">Revision</span>
                  <input type="text" name="driver[revision]" value={@visual_form["revision"]} class="app-input w-full" />
                </label>

                <div class="md:col-span-2">
                  <p class="app-field-label">Channels</p>
                  <div class="mt-3 grid gap-3">
                    <div
                      :for={{channel, index} <- Enum.with_index(channel_form_rows(@visual_form))}
                      class="grid gap-3 rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] p-3 md:grid-cols-[minmax(0,1fr)_auto_auto]"
                    >
                      <label class="space-y-2">
                        <span class="app-field-label">Name</span>
                        <input
                          type="text"
                          name={"driver[channels][#{index}][name]"}
                          value={channel["name"]}
                          class="app-input w-full"
                        />
                      </label>
                      <label class="flex items-center gap-2 pt-7 text-sm text-[var(--app-text-muted)]">
                        <input
                          type="hidden"
                          name={"driver[channels][#{index}][invert?]"}
                          value="false"
                        />
                        <input
                          type="checkbox"
                          name={"driver[channels][#{index}][invert?]"}
                          value="true"
                          checked={channel["invert?"] in ["true", true]}
                        />
                        invert
                      </label>
                      <label
                        :if={@visual_form["device_kind"] == "digital_output"}
                        class="flex items-center gap-2 pt-7 text-sm text-[var(--app-text-muted)]"
                      >
                        <input
                          type="hidden"
                          name={"driver[channels][#{index}][default]"}
                          value="false"
                        />
                        <input
                          type="checkbox"
                          name={"driver[channels][#{index}][default]"}
                          value="true"
                          checked={channel["default"] in ["true", true]}
                        />
                        default on
                      </label>
                    </div>
                  </div>
                </div>
              </form>
            <% end %>
          </div>

          <form :if={@editor_mode == :source} phx-change="change_source" class="mt-5 space-y-3">
            <textarea
              name="draft[source]"
              class="app-textarea h-[32rem] w-full font-mono text-[13px] leading-6"
              phx-debounce="blur"
            ><%= @draft_source %></textarea>
            <p class="text-sm leading-6 text-[var(--app-text-muted)]">
              Source remains authoritative. Visual recovery runs on blur and falls back honestly when unsupported.
            </p>
          </form>

          <div :if={@validation_errors != [] or @sync_diagnostics != []} class="mt-5 space-y-3">
            <div :for={error <- @validation_errors} class="rounded-2xl border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-4 py-3 text-sm text-[var(--app-warn-text)]">
              {format_error(error)}
            </div>
            <div :for={diagnostic <- @sync_diagnostics} class="rounded-2xl border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-4 py-3 text-sm text-[var(--app-info-text)]">
              {format_diagnostic(diagnostic)}
            </div>
          </div>
        </section>
      </div>

      <aside class="space-y-4">
        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Apply Status</p>
          <dl class="mt-4 space-y-3 text-sm leading-6 text-[var(--app-text-muted)]">
            <div>
              <dt class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Current module</dt>
              <dd class="mt-1 text-[var(--app-text)]">{inspect(@runtime_status.module || :none)}</dd>
            </div>
            <div>
              <dt class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Apply state</dt>
              <dd class="mt-1 text-[var(--app-text)]">{format_apply_state(@runtime_status.apply_state)}</dd>
            </div>
            <div>
              <dt class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Applied digest</dt>
              <dd class="mt-1 break-all text-[var(--app-text)]">{@runtime_status.source_digest || "none"}</dd>
            </div>
            <div>
              <dt class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Built digest</dt>
              <dd class="mt-1 break-all text-[var(--app-text)]">{@runtime_status.built_source_digest || "none"}</dd>
            </div>
            <div>
              <dt class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Old code</dt>
              <dd class="mt-1 text-[var(--app-text)]">{if @runtime_status.old_code, do: "draining", else: "clear"}</dd>
            </div>
          </dl>

          <div
            :if={@runtime_status.blocked_reason == :old_code_in_use}
            class="mt-4 rounded-2xl border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-4 py-4 text-sm text-[var(--app-warn-text)]"
          >
            <p class="font-semibold">Apply blocked by old code</p>
            <p class="mt-2 leading-6">
              {length(@runtime_status.lingering_pids)} process(es) still reference the previous module version.
            </p>
            <ul class="mt-2 space-y-1 font-mono text-[12px]">
              <li :for={pid <- @runtime_status.lingering_pids}>{inspect(pid)}</li>
            </ul>
          </div>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Build Diagnostics</p>
          <%= if @driver_draft.build_artifact do %>
            <p class="mt-4 text-sm leading-6 text-[var(--app-text-muted)]">
              Last build prepared <span class="font-semibold text-[var(--app-text)]">{inspect(@driver_draft.build_artifact.module)}</span> without loading it.
            </p>
          <% else %>
            <p class="mt-4 text-sm leading-6 text-[var(--app-text-muted)]">
              No build artifact prepared yet.
            </p>
          <% end %>

          <div class="mt-4 space-y-3">
            <div
              :for={diagnostic <- @driver_draft.build_diagnostics}
              class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-3 text-sm leading-6 text-[var(--app-text-muted)]"
            >
              {format_diagnostic(diagnostic)}
            </div>
          </div>
        </section>

        <section class="app-panel px-5 py-5">
          <p class="app-kicker">Reference Slice</p>
          <ul class="mt-4 space-y-3 text-sm leading-6 text-[var(--app-text-muted)]">
            <li>Generated modules stay thin and delegate runtime behavior to shared helpers.</li>
            <li>Build writes BEAM artifacts without loading them.</li>
            <li>Apply is latest-only and blocks safely when old code still drains.</li>
            <li>Source edits degrade honestly into partial or unsupported visual state.</li>
          </ul>
        </section>
      </aside>
    </section>
    """
  end

  defp load_driver(socket, driver_id) do
    draft = DriverDraftStore.ensure_draft(driver_id)

    model =
      draft.model ||
        case DriverDefinition.from_source(draft.source) do
          {:ok, model} -> model
          {:partial, model, _} -> model
          :unsupported -> nil
        end

    socket
    |> assign(:driver_id, driver_id)
    |> assign(:driver_draft, draft)
    |> assign(:driver_library, DriverDraftStore.list_drafts())
    |> assign(:driver_model, model)
    |> assign(
      :visual_form,
      (model && DriverDefinition.form_from_model(model)) ||
        DriverDefinition.form_from_model(DriverDefinition.default_model(driver_id))
    )
    |> assign(:draft_source, draft.source)
    |> assign(:sync_state, draft.sync_state)
    |> assign(:sync_diagnostics, draft.sync_diagnostics)
    |> assign(:validation_errors, [])
    |> assign(:runtime_status, current_runtime_status(driver_id))
    |> assign(:dirty?, false)
  end

  defp current_runtime_status(driver_id) do
    case Modules.status(driver_id) do
      {:ok, status} ->
        status

      {:error, :not_found} ->
        %{
          module: nil,
          apply_state: :draft,
          source_digest: nil,
          built_source_digest: nil,
          old_code: false,
          blocked_reason: nil,
          lingering_pids: [],
          last_build_at: nil,
          last_apply_at: nil
        }
    end
  end

  defp normalize_visual_form(params, existing_form) do
    base = Map.merge(existing_form, params)
    channel_count = Map.get(base, "channel_count", existing_form["channel_count"] || "1")

    count =
      case Integer.parse(to_string(channel_count)) do
        {value, ""} when value > 0 -> min(value, 32)
        _ -> length(channel_form_rows(existing_form))
      end

    existing_channels = Map.get(existing_form, "channels", %{})
    new_channels = Map.get(params, "channels", %{})

    channels =
      0..max(count - 1, 0)
      |> Enum.map(fn index ->
        key = Integer.to_string(index)
        fallback = Map.get(existing_channels, key, %{})
        current = Map.get(new_channels, key, %{})

        {key,
         %{
           "name" => Map.get(current, "name", Map.get(fallback, "name", "ch#{index + 1}")),
           "invert?" =>
             checkbox_form_value(
               Map.get(current, "invert?", Map.get(fallback, "invert?", "false"))
             ),
           "default" =>
             checkbox_form_value(
               Map.get(current, "default", Map.get(fallback, "default", "false"))
             )
         }}
      end)
      |> Map.new()

    base
    |> Map.put("channel_count", Integer.to_string(count))
    |> Map.put("channels", channels)
  end

  defp channel_form_rows(form) do
    form
    |> Map.get("channels", %{})
    |> Enum.sort_by(fn {key, _value} -> String.to_integer(key) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp checkbox_form_value(value) when value in ["true", true, "on", "1", 1], do: "true"
  defp checkbox_form_value(_value), do: "false"

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}
  defp mode_label(:visual), do: "Visual"
  defp mode_label(:source), do: "Source"
  defp sync_label(:synced), do: "Visuals synced"
  defp sync_label(:partial), do: "Partial visual recovery"
  defp sync_label(:unsupported), do: "Visuals unavailable"

  defp mode_button_classes(true),
    do: "app-button"

  defp mode_button_classes(false),
    do: "app-button-secondary"

  defp sync_badge_classes(:synced),
    do:
      "rounded-full border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-3 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-[var(--app-good-text)]"

  defp sync_badge_classes(:partial),
    do:
      "rounded-full border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-3 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-[var(--app-warn-text)]"

  defp sync_badge_classes(:unsupported),
    do:
      "rounded-full border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-3 py-2 text-xs font-semibold uppercase tracking-[0.2em] text-[var(--app-danger-text)]"

  defp artifact_link_classes(true), do: "app-button-secondary"
  defp artifact_link_classes(false), do: "app-link"

  defp feedback_classes(:ok),
    do:
      "mt-4 rounded-2xl border border-[var(--app-good-border)] bg-[var(--app-good-surface)] px-4 py-4 text-[var(--app-good-text)]"

  defp feedback_classes(:warn),
    do:
      "mt-4 rounded-2xl border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-4 py-4 text-[var(--app-warn-text)]"

  defp feedback_classes(_other),
    do:
      "mt-4 rounded-2xl border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-4 py-4 text-[var(--app-danger-text)]"

  defp format_error(%{field: field, message: message}), do: "#{field}: #{message}"
  defp format_error(other), do: inspect(other)

  defp format_diagnostic(%{file: file, position: position, message: message}),
    do: "#{file}:#{inspect(position)} #{message}"

  defp format_diagnostic(%{message: message}), do: message
  defp format_diagnostic(other), do: inspect(other)
  defp format_apply_state(nil), do: "draft"
  defp format_apply_state(state) when is_atom(state), do: Atom.to_string(state)
end
