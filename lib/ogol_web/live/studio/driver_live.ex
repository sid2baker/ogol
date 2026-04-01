defmodule OgolWeb.Studio.DriverLive do
  use OgolWeb, :live_view

  alias Ogol.Driver.Source, as: DriverSource
  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Studio.Library, as: StudioLibrary
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias OgolWeb.Live.SessionAction, as: SessionAction
  alias OgolWeb.Live.SessionSync
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell, as: StudioCellModel
  alias Ogol.Driver.Studio.Cell, as: DriverCell
  alias Ogol.Session

  @views [:visual, :source]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Driver Studio")
     |> assign(
       :page_summary,
       "Generate thin EtherCAT driver modules from a constrained model and compile them into the selected runtime from the shared hardware shell."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :hardware)
     |> assign(:hmi_subnav, :drivers)
     |> assign(:requested_view, :visual)
     |> assign(:driver_issue, nil)
     |> StudioRevision.subscribe()
     |> load_driver(nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> StudioRevision.apply_param(params)
      |> SessionSync.ensure_entry(:driver, params["driver_id"])

    {:noreply, load_driver(socket, params["driver_id"])}
  end

  @impl true
  def handle_info({:operations, operations}, socket) do
    {:noreply,
     socket
     |> StudioRevision.apply_operations(operations)
     |> load_driver(socket.assigns[:driver_id])}
  end

  def handle_info({:workspace_updated, _operation, _reply, _session}, socket) do
    {:noreply,
     socket
     |> StudioRevision.sync_session()
     |> load_driver(socket.assigns[:driver_id])}
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
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_driver(socket)}
    else
      draft = Session.create_driver()
      {:noreply, push_patch(socket, to: ~p"/studio/drivers/#{draft.id}")}
    end
  end

  def handle_event("change_visual", %{"driver" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_driver(socket)}
    else
      visual_form = normalize_visual_form(params, socket.assigns.visual_form)

      case DriverSource.cast_model(visual_form) do
        {:ok, model} ->
          source =
            DriverSource.to_source(
              DriverSource.module_from_name!(model.module_name),
              model
            )

          draft =
            Session.save_driver_source(
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
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_driver(socket)}
    else
      {socket, sync_state, model, sync_diagnostics} =
        case DriverSource.from_source(source) do
          {:ok, model} ->
            {socket
             |> assign(:driver_model, model)
             |> assign(:visual_form, DriverSource.form_from_model(model))
             |> assign(:sync_diagnostics, [])
             |> assign(:validation_errors, []), :synced, model, []}

          {:partial, model, diagnostics} ->
            {socket
             |> assign(:driver_model, model)
             |> assign(:visual_form, DriverSource.form_from_model(model))
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
        Session.save_driver_source(
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
  end

  def handle_event("request_transition", %{"transition" => "compile"}, socket) do
    case current_driver_action(socket.assigns, "compile") do
      nil ->
        {:noreply, socket}

      action ->
        SessionAction.reduce_action(
          socket,
          action,
          after: fn socket, reply ->
            case reply do
              {:error, :module_not_found} ->
                assign(
                  socket,
                  :driver_issue,
                  {:compile_missing_module,
                   "Source must define one driver module before it can be compiled."}
                )

              _other ->
                socket
                |> assign(:runtime_status, current_runtime_status(socket.assigns.driver_id))
                |> assign(:driver_issue, nil)
            end
          end
        )
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:driver_cell, current_driver_cell(assigns))
      |> assign(
        :driver_items,
        driver_items(assigns.driver_library, assigns.driver_id, assigns.studio_selected_revision)
      )

    ~H"""
    <section class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
      <StudioLibrary.list title="Drivers" items={@driver_items} current_id={@driver_id}>
        <:actions>
          <button
            type="button"
            phx-click="new_driver"
            class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
            disabled={@studio_read_only?}
            title={if(@studio_read_only?, do: StudioRevision.readonly_message())}
          >
            New
          </button>
        </:actions>
      </StudioLibrary.list>

      <StudioCell.cell :if={@driver_draft} body_class="min-h-[42rem]">
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
            read_only?={@studio_read_only?}
          />

          <.source_editor
            :if={@driver_cell.selected_view == :source}
            draft_source={@draft_source}
            read_only?={@studio_read_only?}
          />
        </:body>
      </StudioCell.cell>

      <section :if={!@driver_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Drivers</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          The current workspace does not contain any drivers
        </h2>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          Load a revision that includes drivers, or create a new driver in Draft mode.
        </p>
      </section>
    </section>
    """
  end

  defp load_driver(socket, driver_id) do
    {resolved_driver_id, draft, library} = driver_snapshot(socket, driver_id)

    if draft do
      model =
        draft.model ||
          case DriverSource.from_source(draft.source) do
            {:ok, model} -> model
            {:partial, model, _} -> model
            :unsupported -> nil
          end

      socket
      |> assign(:driver_id, resolved_driver_id)
      |> assign(:driver_draft, draft)
      |> assign(:driver_library, library)
      |> assign(:driver_model, model)
      |> assign(
        :visual_form,
        (model && DriverSource.form_from_model(model)) ||
          DriverSource.form_from_model(DriverSource.default_model(resolved_driver_id))
      )
      |> assign(:draft_source, draft.source)
      |> assign(:current_source_digest, Build.digest(draft.source))
      |> assign(:sync_state, draft.sync_state)
      |> assign(:sync_diagnostics, draft.sync_diagnostics)
      |> assign(:validation_errors, [])
      |> assign(:driver_issue, nil)
      |> assign(:runtime_status, current_runtime_status(resolved_driver_id))
    else
      socket
      |> assign(:driver_id, nil)
      |> assign(:driver_draft, nil)
      |> assign(:driver_library, library)
      |> assign(:driver_model, nil)
      |> assign(
        :visual_form,
        DriverSource.form_from_model(DriverSource.default_model("driver"))
      )
      |> assign(:draft_source, "")
      |> assign(:current_source_digest, Build.digest(""))
      |> assign(:sync_state, :synced)
      |> assign(:sync_diagnostics, [])
      |> assign(:validation_errors, [])
      |> assign(:driver_issue, nil)
      |> assign(:runtime_status, DriverCell.default_runtime_status())
    end
  end

  defp driver_snapshot(socket, requested_id) do
    drafts = SessionSync.list_entries(socket, :driver)
    draft = select_driver_draft(drafts, requested_id)
    {draft && draft.id, draft, drafts}
  end

  defp select_driver_draft(drafts, requested_id) do
    Enum.find(drafts, &(&1.id == requested_id)) ||
      Enum.find(drafts, &(&1.id == Session.driver_default_id())) ||
      List.first(drafts)
  end

  defp current_runtime_status(driver_id) do
    case Session.runtime_status(:driver, driver_id) do
      {:ok, status} ->
        status

      {:error, :not_found} ->
        DriverCell.default_runtime_status()
    end
  end

  defp current_driver_cell(assigns) do
    assigns
    |> DriverCell.facts_from_assigns()
    |> then(&StudioCellModel.derive(DriverCell, &1))
  end

  defp current_driver_action(assigns, transition) do
    assigns
    |> current_driver_cell()
    |> StudioCellModel.action_for_transition(transition)
  end

  defp driver_items(drafts, current_id, selected_revision) do
    Enum.map(drafts, fn draft ->
      %{
        id: draft.id,
        label: driver_label(draft),
        detail: driver_detail(draft),
        path:
          StudioRevision.path_with_revision(~p"/studio/drivers/#{draft.id}", selected_revision),
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
  attr(:read_only?, :boolean, default: false)

  defp visual_editor(assigns) do
    ~H"""
    <form phx-change="change_visual" class="space-y-5">
      <fieldset disabled={@read_only?} class="contents">
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
      </fieldset>
    </form>
    """
  end

  attr(:draft_source, :string, required: true)
  attr(:read_only?, :boolean, default: false)

  defp source_editor(assigns) do
    ~H"""
    <form phx-change="change_source" class="space-y-3">
      <fieldset disabled={@read_only?} class="contents">
      <textarea
        name="draft[source]"
        class="app-textarea h-[34rem] w-full font-mono text-[13px] leading-6"
        phx-debounce="blur"
      ><%= @draft_source %></textarea>
      <p class="text-sm leading-6 text-[var(--app-text-muted)]">
        Source is autosaved on blur. Visual recovery runs only when the code remains inside the supported generated subset.
      </p>
      </fieldset>
    </form>
    """
  end

  defp readonly_driver(socket) do
    assign(socket, :driver_issue, {:revision_read_only, StudioRevision.readonly_message()})
  end
end
