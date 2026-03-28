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

        draft =
          DriverDraftStore.save_source(
            socket.assigns.driver_id,
            source,
            model,
            :synced,
            []
          )

        {:noreply,
         socket
         |> assign(:driver_draft, draft)
         |> assign(:visual_form, visual_form)
         |> assign(:driver_model, model)
         |> assign(:draft_source, source)
         |> assign(:current_source_digest, Build.digest(source))
         |> assign(:sync_state, :synced)
         |> assign(:sync_diagnostics, [])
         |> assign(:validation_errors, [])
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
    {socket, sync_state, model, sync_diagnostics} =
      case DriverDefinition.from_source(source) do
        {:ok, model} ->
          {socket
           |> assign(:driver_model, model)
           |> assign(:visual_form, DriverDefinition.form_from_model(model))
           |> assign(:sync_diagnostics, [])
           |> assign(:validation_errors, []), :synced, model, []}

        {:partial, model, diagnostics} ->
          {socket
           |> assign(:driver_model, model)
           |> assign(:visual_form, DriverDefinition.form_from_model(model))
           |> assign(:sync_diagnostics, diagnostics)
           |> assign(:validation_errors, []), :partial, model, diagnostics}

        :unsupported ->
          {socket
           |> assign(:driver_model, nil)
           |> assign(
             :sync_diagnostics,
             ["Current source can no longer be represented by the visual editor."]
           )
           |> assign(:editor_mode, :source)
           |> assign(:validation_errors, []), :unsupported, nil,
           ["Current source can no longer be represented by the visual editor."]}
      end

    draft =
      DriverDraftStore.save_source(
        socket.assigns.driver_id,
        source,
        model,
        sync_state,
        sync_diagnostics
      )

    {:noreply,
     socket
     |> assign(:driver_draft, draft)
     |> assign(:draft_source, source)
     |> assign(:current_source_digest, Build.digest(source))
     |> assign(:sync_state, sync_state)
     |> assign(:studio_feedback, nil)}
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
       |> assign(:studio_feedback, nil)}
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
             |> assign(:studio_feedback, nil)}

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
    <section class="mx-auto max-w-7xl">
      <section class="app-panel px-5 py-5">
        <div class="flex flex-col gap-4">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex flex-wrap items-center gap-2">
              <button
                :if={show_build?(assigns)}
                type="button"
                phx-click="build_driver"
                class="app-button-secondary"
              >
                Build
              </button>
              <button
                :if={show_apply?(assigns)}
                type="button"
                phx-click="apply_driver"
                class="app-button"
              >
                Apply
              </button>
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
            </div>
          </div>

          <div class="grid gap-4 xl:grid-cols-[minmax(0,1.2fr)_minmax(18rem,0.8fr)] xl:items-start">
            <div>
              <p class="app-kicker">Studio Cell</p>
              <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
                {@driver_model && @driver_model.label || "Driver Studio"}
              </h2>
              <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                Generate thin EtherCAT driver modules from a constrained visual model or canonical source. Builds stay non-loading. Apply stays latest-only and gated.
              </p>
            </div>

            <div class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
              <p class="app-kicker">Runtime</p>
              <p class="mt-2 text-sm font-semibold text-[var(--app-text)]">
                {status_summary(assigns)}
              </p>
              <dl class="mt-3 grid gap-3 text-sm leading-6 text-[var(--app-text-muted)]">
                <div>
                  <dt class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Current module</dt>
                  <dd class="mt-1 break-all text-[var(--app-text)]">{format_module(@runtime_status.module)}</dd>
                </div>
                <div :if={@runtime_status.blocked_reason == :old_code_in_use}>
                  <dt class="font-mono text-[11px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Old code drain</dt>
                  <dd class="mt-1 text-[var(--app-text)]">{length(@runtime_status.lingering_pids)} lingering process(es)</dd>
                </div>
              </dl>
            </div>
          </div>

          <form phx-submit="open_driver" class="grid gap-3 md:grid-cols-[minmax(0,1fr)_auto]">
            <label class="space-y-2">
              <span class="app-field-label">Artifact Id</span>
              <input
                type="text"
                name="artifact[id]"
                value={@driver_id}
                class="app-input w-full"
                autocomplete="off"
              />
            </label>
            <button type="submit" class="app-button-secondary self-end">
              Open Draft
            </button>
          </form>

          <div class="flex flex-wrap gap-2">
            <.link
              :for={draft <- @driver_library}
              navigate={~p"/studio/drivers/#{draft.id}"}
              class={artifact_link_classes(draft.id == @driver_id)}
            >
              {draft.id}
            </.link>
          </div>

          <div :for={banner <- banners(assigns)} class={feedback_classes(banner.level)}>
            <p class="font-semibold">{banner.title}</p>
            <p class="mt-1 text-sm leading-6">{banner.detail}</p>
          </div>

          <%= if @editor_mode == :visual and @sync_state != :unsupported do %>
            <form phx-change="change_visual" class="space-y-5">
              <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-6">
                <label class="space-y-2">
                  <span class="app-field-label">Logical Id</span>
                  <input type="text" name="driver[id]" value={@visual_form["id"]} class="app-input w-full" readonly />
                </label>
                <label class="space-y-2 xl:col-span-2">
                  <span class="app-field-label">Module</span>
                  <input type="text" name="driver[module_name]" value={@visual_form["module_name"]} class="app-input w-full" />
                </label>
                <label class="space-y-2 xl:col-span-3">
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
              </div>

              <div class="border-t border-[var(--app-border)] pt-5">
                <div class="flex items-center justify-between gap-3">
                  <div>
                    <p class="app-kicker">Channels</p>
                    <p class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">
                      Channel-level naming and defaults. Changes autosave immediately into canonical source.
                    </p>
                  </div>
                  <div class="text-sm text-[var(--app-text-muted)]">
                    {length(channel_form_rows(@visual_form))} channel(s)
                  </div>
                </div>

                <div class="mt-4 grid gap-3 xl:grid-cols-2">
                  <div
                    :for={{channel, index} <- Enum.with_index(channel_form_rows(@visual_form))}
                    class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
                  >
                    <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_auto_auto]">
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
              </div>
            </form>
          <% else %>
            <div :if={@editor_mode == :visual and @sync_state == :unsupported} class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-5">
              <p class="font-semibold text-[var(--app-text)]">Visual editor unavailable for current source</p>
              <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                This Studio Cell stays source-first until the current code returns to a supported generated shape.
              </p>
            </div>
          <% end %>

          <form :if={@editor_mode == :source} phx-change="change_source" class="space-y-3">
            <textarea
              name="draft[source]"
              class="app-textarea h-[34rem] w-full font-mono text-[13px] leading-6"
              phx-debounce="blur"
            ><%= @draft_source %></textarea>
            <p class="text-sm leading-6 text-[var(--app-text-muted)]">
              Source is autosaved on blur. Visual recovery runs only when the code remains inside the supported generated subset.
            </p>
          </form>

          <div class="mt-5 border-t border-[var(--app-border)] pt-5">
            <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,0.9fr)]">
              <div>
                <p class="app-kicker">Current Cell State</p>
                <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                  {status_detail(assigns)}
                </p>
              </div>
              <div :if={@driver_draft.build_diagnostics != []} class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
                <p class="app-kicker">Build Diagnostics</p>
                <div class="mt-3 space-y-2">
                  <p
                    :for={diagnostic <- @driver_draft.build_diagnostics}
                    class="text-sm leading-6 text-[var(--app-text-muted)]"
                  >
                    {format_diagnostic(diagnostic)}
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>
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
    |> assign(:current_source_digest, Build.digest(draft.source))
    |> assign(:sync_state, draft.sync_state)
    |> assign(:sync_diagnostics, draft.sync_diagnostics)
    |> assign(:validation_errors, [])
    |> assign(:runtime_status, current_runtime_status(driver_id))
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

  defp mode_button_classes(true),
    do: "app-button"

  defp mode_button_classes(false),
    do: "app-button-secondary"

  defp artifact_link_classes(true), do: "app-button-secondary"
  defp artifact_link_classes(false), do: "app-link"

  defp feedback_classes(:warn),
    do:
      "rounded-2xl border border-[var(--app-warn-border)] bg-[var(--app-warn-surface)] px-4 py-4 text-[var(--app-warn-text)]"

  defp feedback_classes(:info),
    do:
      "rounded-2xl border border-[var(--app-info-border)] bg-[var(--app-info-surface)] px-4 py-4 text-[var(--app-info-text)]"

  defp feedback_classes(_other),
    do:
      "rounded-2xl border border-[var(--app-danger-border)] bg-[var(--app-danger-surface)] px-4 py-4 text-[var(--app-danger-text)]"

  defp format_error(%Zoi.Error{path: path, message: message}) do
    case path do
      [] -> message
      _ -> "#{format_error_path(path)}: #{message}"
    end
  end

  defp format_error(%{field: field, message: message}), do: "#{field}: #{message}"
  defp format_error(other), do: inspect(other)

  defp format_diagnostic(%{file: file, position: position, message: message}),
    do: "#{file}:#{inspect(position)} #{message}"

  defp format_diagnostic(%{message: message}), do: message
  defp format_diagnostic(other), do: inspect(other)

  defp format_module(nil), do: "none"
  defp format_module(module), do: inspect(module)

  defp show_build?(assigns) do
    not visual_invalid?(assigns) and
      assigns.current_source_digest != assigns.runtime_status.built_source_digest
  end

  defp show_apply?(assigns) do
    not visual_invalid?(assigns) and
      current_build_artifact?(assigns) and
      assigns.current_source_digest != assigns.runtime_status.source_digest
  end

  defp visual_invalid?(assigns) do
    assigns.editor_mode == :visual and assigns.validation_errors != []
  end

  defp current_build_artifact?(assigns) do
    case assigns.driver_draft.build_artifact do
      %{source_digest: digest} -> digest == assigns.current_source_digest
      _ -> false
    end
  end

  defp status_summary(assigns) do
    cond do
      visual_invalid?(assigns) ->
        "Visual edit is incomplete"

      assigns.runtime_status.blocked_reason == :old_code_in_use ->
        "Apply blocked while old code drains"

      show_apply?(assigns) ->
        "Build ready to apply"

      assigns.current_source_digest == assigns.runtime_status.source_digest and
          assigns.runtime_status.apply_state == :applied ->
        "Current source is applied"

      show_build?(assigns) ->
        "Source changed and needs a build"

      true ->
        "Draft is ready"
    end
  end

  defp status_detail(assigns) do
    cond do
      visual_invalid?(assigns) ->
        "The current visual edit has validation problems, so build and apply stay hidden until the canonical source is consistent again."

      assigns.runtime_status.blocked_reason == :old_code_in_use ->
        "A new artifact is ready, but apply is blocked until lingering processes leave the old module."

      show_apply?(assigns) ->
        "This cell has a current build artifact that has not been applied yet."

      assigns.current_source_digest == assigns.runtime_status.source_digest and
          assigns.runtime_status.apply_state == :applied ->
        "The applied module matches the current canonical source for this driver."

      show_build?(assigns) ->
        "The current source differs from the last built artifact. Build when you want a fresh BEAM artifact."

      true ->
        "This driver cell is idle. Changes autosave immediately and only surface banners when something needs attention."
    end
  end

  defp banners(assigns) do
    []
    |> maybe_add_feedback(assigns.studio_feedback)
    |> maybe_add_validation_errors(assigns.validation_errors)
    |> maybe_add_sync_warning(assigns.sync_state, assigns.sync_diagnostics)
  end

  defp maybe_add_feedback(banners, %{level: :ok}), do: banners
  defp maybe_add_feedback(banners, nil), do: banners
  defp maybe_add_feedback(banners, feedback), do: banners ++ [feedback]

  defp maybe_add_validation_errors(banners, []), do: banners

  defp maybe_add_validation_errors(banners, errors) do
    banners ++
      Enum.map(errors, fn error ->
        %{
          level: :warn,
          title: "Visual update blocked",
          detail: format_error(error)
        }
      end)
  end

  defp maybe_add_sync_warning(banners, :partial, diagnostics) do
    banners ++
      [
        %{
          level: :warn,
          title: "Partial visual recovery",
          detail: Enum.map_join(diagnostics, " ", &format_diagnostic/1)
        }
      ]
  end

  defp maybe_add_sync_warning(banners, :unsupported, diagnostics) do
    banners ++
      [
        %{
          level: :error,
          title: "Visual editor unavailable",
          detail: Enum.map_join(diagnostics, " ", &format_diagnostic/1)
        }
      ]
  end

  defp maybe_add_sync_warning(banners, _state, _diagnostics), do: banners

  defp format_error_path(path) do
    path
    |> Enum.map(fn
      key when is_integer(key) -> "[#{key}]"
      key when is_atom(key) -> Atom.to_string(key)
      key -> to_string(key)
    end)
    |> Enum.reduce("", fn segment, acc ->
      cond do
        acc == "" ->
          segment

        String.starts_with?(segment, "[") ->
          acc <> segment

        true ->
          acc <> "." <> segment
      end
    end)
  end
end
