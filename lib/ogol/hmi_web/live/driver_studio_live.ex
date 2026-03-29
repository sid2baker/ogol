defmodule Ogol.HMIWeb.DriverStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMIWeb.Components.{StudioCell, StudioLibrary}
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell
  alias Ogol.Studio.DriverCell
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore
  alias Ogol.Studio.DriverParser
  alias Ogol.Studio.Modules

  @views [:visual, :source]

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
     |> assign(:requested_view, :visual)
     |> assign(:driver_issue, nil)
     |> load_driver(DriverDraftStore.default_id())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_driver(socket, params["driver_id"] || DriverDraftStore.default_id())}
  end

  @impl true
  def handle_event("select_view", %{"view" => view}, socket) do
    view =
      view
      |> String.to_existing_atom()
      |> then(fn view -> if view in @views, do: view, else: :visual end)

    {:noreply, assign(socket, :requested_view, view)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("new_driver", _params, socket) do
    draft = DriverDraftStore.create_draft()
    {:noreply, push_patch(socket, to: ~p"/studio/drivers/#{draft.id}")}
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
         |> assign(:driver_issue, nil)}

      {:error, error} ->
        {:noreply,
         socket
         |> assign(:visual_form, visual_form)
         |> assign(:validation_errors, [error])
         |> assign(:driver_issue, nil)}
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
     |> assign(:driver_issue, nil)}
  end

  def handle_event("request_transition", %{"transition" => "build"}, socket) do
    with {:ok, module} <- DriverParser.module_from_source(socket.assigns.draft_source),
         {:ok, artifact} <-
           Build.build(socket.assigns.driver_id, module, socket.assigns.draft_source) do
      draft =
        DriverDraftStore.record_build(socket.assigns.driver_id, artifact, artifact.diagnostics)

      {:noreply,
       socket
       |> assign(:driver_draft, draft)
       |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
       |> assign(:driver_issue, nil)}
    else
      {:error, %{diagnostics: diagnostics}} ->
        draft = DriverDraftStore.record_build(socket.assigns.driver_id, nil, diagnostics)

        {:noreply,
         socket
         |> assign(:driver_draft, draft)
         |> assign(:driver_issue, nil)}

      {:error, :module_not_found} ->
        {:noreply,
         assign(
           socket,
           :driver_issue,
           {:build_missing_module, "Source must define one driver module before it can be built."}
         )}
    end
  end

  def handle_event("request_transition", %{"transition" => "apply"}, socket) do
    case socket.assigns.driver_draft.build_artifact do
      nil ->
        {:noreply,
         assign(
           socket,
           :driver_issue,
           {:apply_without_build, "Build a valid artifact before applying it."}
         )}

      artifact ->
        case Modules.apply(socket.assigns.driver_id, artifact) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
             |> assign(:driver_issue, nil)}

          {:blocked, %{pids: _pids}} ->
            {:noreply,
             socket
             |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
             |> assign(:driver_issue, nil)}

          {:error, {:module_mismatch, _expected, _actual}} ->
            {:noreply,
             socket
             |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
             |> assign(:driver_issue, nil)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
             |> assign(:driver_issue, nil)}
        end
    end
  end

  @impl true
  def render(assigns) do
    driver_facts = DriverCell.facts_from_assigns(assigns)

    assigns =
      assigns
      |> assign(:driver_cell, Cell.derive(DriverCell, driver_facts))
      |> assign(:driver_items, driver_items(assigns.driver_library, assigns.driver_id))

    ~H"""
    <section class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
      <StudioLibrary.list title="Drivers" items={@driver_items} current_id={@driver_id}>
        <:actions>
          <button type="button" phx-click="new_driver" class="app-button-secondary">
            New
          </button>
        </:actions>
      </StudioLibrary.list>

      <StudioCell.cell body_class="min-h-[42rem]">
        <:actions>
          <StudioCell.action_button
            :for={action <- @driver_cell.actions}
            type="button"
            phx-click="request_transition"
            phx-value-transition={action.id}
            variant={action.variant}
            disabled={!action.enabled?}
            title={action.disabled_reason}
          >
            {action.label}
          </StudioCell.action_button>
        </:actions>

        <:views>
          <StudioCell.view_button
            :for={view <- @driver_cell.views}
            type="button"
            phx-click="select_view"
            phx-value-view={view.id}
            selected={@driver_cell.selected_view == view.id}
            available={view.available?}
          >
            {view.label}
          </StudioCell.view_button>
        </:views>

        <:notice :if={@driver_cell.notice}>
          <StudioCell.notice
            tone={@driver_cell.notice.tone}
            title={@driver_cell.notice.title}
            message={@driver_cell.notice.message}
          />
        </:notice>

        <:body>
          <.visual_editor
            :if={@driver_cell.selected_view == :visual}
            visual_form={@visual_form}
          />

          <.source_editor :if={@driver_cell.selected_view == :source} draft_source={@draft_source} />
        </:body>
      </StudioCell.cell>
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
    |> assign(:driver_issue, nil)
    |> assign(:runtime_status, current_runtime_status(driver_id))
  end

  defp current_runtime_status(driver_id) do
    case Modules.status(driver_id) do
      {:ok, status} ->
        status

      {:error, :not_found} ->
        DriverCell.default_runtime_status()
    end
  end

  defp driver_items(drafts, current_id) do
    Enum.map(drafts, fn draft ->
      %{
        id: draft.id,
        label: driver_label(draft),
        detail: driver_detail(draft),
        path: ~p"/studio/drivers/#{draft.id}",
        status:
          if(draft.id == current_id, do: "open", else: humanize_sync_state(draft.sync_state))
      }
    end)
  end

  defp driver_label(%{model: %{label: label}}) when is_binary(label) and label != "", do: label

  defp driver_label(draft) do
    draft.id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp driver_detail(%{model: %{device_kind: device_kind, channels: channels}})
       when is_atom(device_kind) and is_list(channels) do
    "#{device_kind} • #{length(channels)} channel(s)"
  end

  defp driver_detail(_draft), do: "Source-only draft"

  defp humanize_sync_state(:synced), do: "Synced"
  defp humanize_sync_state(:partial), do: "Partial"
  defp humanize_sync_state(:unsupported), do: "Source-only"
  defp humanize_sync_state(other), do: other |> to_string() |> String.capitalize()

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

  attr(:visual_form, :map, required: true)

  defp visual_editor(assigns) do
    ~H"""
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
    """
  end

  attr(:draft_source, :string, required: true)

  defp source_editor(assigns) do
    ~H"""
    <form phx-change="change_source" class="space-y-3">
      <textarea
        name="draft[source]"
        class="app-textarea h-[34rem] w-full font-mono text-[13px] leading-6"
        phx-debounce="blur"
      ><%= @draft_source %></textarea>
      <p class="text-sm leading-6 text-[var(--app-text-muted)]">
        Source is autosaved on blur. Visual recovery runs only when the code remains inside the supported generated subset.
      </p>
    </form>
    """
  end
end
