defmodule Ogol.HMIWeb.MachineStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMIWeb.Components.{StudioCell, StudioLibrary}
  alias Ogol.Studio.MachineDefinition
  alias Ogol.Studio.MachineDraftStore

  @editor_modes [:visual, :source]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Machine Studio")
     |> assign(
       :page_summary,
       "Author canonical machine modules from a constrained visual subset or edit the source directly when the machine leaves that subset."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :machines)
     |> assign(:editor_modes, @editor_modes)
     |> assign(:editor_mode, :visual)
     |> load_machine(MachineDraftStore.default_id())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_machine(socket, params["machine_id"] || MachineDraftStore.default_id())}
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

  def handle_event("new_machine", _params, socket) do
    draft = MachineDraftStore.create_draft()
    {:noreply, push_patch(socket, to: ~p"/studio/machines/#{draft.id}")}
  end

  def handle_event("change_visual", %{"machine" => params}, socket) do
    visual_form = normalize_visual_form(params, socket.assigns.visual_form)

    case MachineDefinition.cast_model(visual_form) do
      {:ok, model} ->
        source = MachineDefinition.to_source(model)

        draft =
          MachineDraftStore.save_source(
            socket.assigns.machine_id,
            source,
            model,
            :synced,
            []
          )

        {:noreply,
         socket
         |> assign(:machine_draft, draft)
         |> assign(:machine_model, model)
         |> assign(:visual_form, MachineDefinition.form_from_model(model))
         |> assign(:draft_source, source)
         |> assign(:sync_state, :synced)
         |> assign(:sync_diagnostics, [])
         |> assign(:validation_errors, [])}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:visual_form, visual_form)
         |> assign(:validation_errors, errors)}
    end
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    {model, sync_state, diagnostics, editor_mode} =
      case MachineDefinition.from_source(source) do
        {:ok, model} ->
          {model, :synced, [], socket.assigns.editor_mode}

        {:error, diagnostics} ->
          {nil, :unsupported, diagnostics, :source}
      end

    draft =
      MachineDraftStore.save_source(
        socket.assigns.machine_id,
        source,
        model,
        sync_state,
        diagnostics
      )

    {:noreply,
     socket
     |> assign(:machine_draft, draft)
     |> assign(:machine_model, model)
     |> assign(:draft_source, source)
     |> assign(
       :visual_form,
       (model && MachineDefinition.form_from_model(model)) || socket.assigns.visual_form
     )
     |> assign(:sync_state, sync_state)
     |> assign(:sync_diagnostics, diagnostics)
     |> assign(:validation_errors, [])
     |> assign(:editor_mode, editor_mode)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:header_notice, header_notice(assigns))
      |> assign(:machine_items, machine_items(assigns.machine_library, assigns.machine_id))

    ~H"""
    <section class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
      <StudioLibrary.list title="Machines" items={@machine_items} current_id={@machine_id}>
        <:actions>
          <button type="button" phx-click="new_machine" class="app-button-secondary">
            New
          </button>
        </:actions>
      </StudioLibrary.list>

      <StudioCell.cell body_class="min-h-[72rem]">
        <:views>
          <StudioCell.view_button
            :for={mode <- @editor_modes}
            type="button"
            phx-click="set_editor_mode"
            phx-value-mode={mode}
            selected={@editor_mode == mode}
          >
            {mode_label(mode)}
          </StudioCell.view_button>
        </:views>

        <:notice :if={@header_notice}>
          <StudioCell.notice
            tone={@header_notice.level}
            title={@header_notice.title}
            message={@header_notice.detail}
          />
        </:notice>

        <:body>
          <.visual_editor
            :if={@editor_mode == :visual and @sync_state != :unsupported}
            visual_form={@visual_form}
          />

          <.visual_unavailable :if={@editor_mode == :visual and @sync_state == :unsupported} />

          <.source_editor :if={@editor_mode == :source} draft_source={@draft_source} />
        </:body>
      </StudioCell.cell>
    </section>
    """
  end

  defp load_machine(socket, machine_id) do
    draft = MachineDraftStore.ensure_draft(machine_id)

    model =
      draft.model ||
        case MachineDefinition.from_source(draft.source) do
          {:ok, model} -> model
          {:error, _diagnostics} -> nil
        end

    socket
    |> assign(:machine_id, machine_id)
    |> assign(:machine_draft, draft)
    |> assign(:machine_library, MachineDraftStore.list_drafts())
    |> assign(:machine_model, model)
    |> assign(
      :visual_form,
      (model && MachineDefinition.form_from_model(model)) ||
        MachineDefinition.form_from_model(MachineDefinition.default_model(machine_id))
    )
    |> assign(:draft_source, draft.source)
    |> assign(:sync_state, draft.sync_state)
    |> assign(:sync_diagnostics, draft.sync_diagnostics)
    |> assign(:validation_errors, [])
  end

  defp machine_items(drafts, current_id) do
    Enum.map(drafts, fn draft ->
      %{
        id: draft.id,
        label: machine_label(draft),
        detail: machine_detail(draft),
        path: ~p"/studio/machines/#{draft.id}",
        status:
          if(draft.id == current_id, do: "open", else: humanize_sync_state(draft.sync_state))
      }
    end)
  end

  defp machine_label(%{model: %{meaning: meaning}}) when is_binary(meaning) and meaning != "",
    do: meaning

  defp machine_label(draft),
    do:
      draft.id
      |> String.replace("_", " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)

  defp machine_detail(%{model: model}) when is_map(model), do: MachineDefinition.summary(model)
  defp machine_detail(_draft), do: "Source-only draft"

  defp mode_label(:visual), do: "Visual"
  defp mode_label(:source), do: "Source"

  defp humanize_sync_state(:synced), do: "Synced"
  defp humanize_sync_state(:unsupported), do: "Source-only"
  defp humanize_sync_state(other), do: other |> to_string() |> String.capitalize()

  defp header_notice(%{validation_errors: [first | _]}) do
    %{level: :error, title: "Visual validation", detail: first}
  end

  defp header_notice(%{sync_state: :unsupported, sync_diagnostics: [first | _]}) do
    %{level: :warn, title: "Source only", detail: first}
  end

  defp header_notice(_assigns), do: nil

  defp normalize_visual_form(params, existing_form) do
    existing_form
    |> Map.merge(params)
    |> Map.update("machine_id", existing_form["machine_id"], &to_string/1)
    |> Map.update("module_name", existing_form["module_name"], &to_string/1)
    |> Map.update("meaning", existing_form["meaning"], &to_string/1)
  end

  attr(:visual_form, :map, required: true)

  defp visual_editor(assigns) do
    ~H"""
    <form phx-change="change_visual" class="grid h-full w-full content-start gap-5">
      <section class="grid gap-4 xl:grid-cols-3">
        <label class="space-y-2">
          <span class="app-field-label">Machine Id</span>
          <input type="text" name="machine[machine_id]" value={@visual_form["machine_id"]} class="app-input w-full" />
        </label>

        <label class="space-y-2 xl:col-span-2">
          <span class="app-field-label">Module Name</span>
          <input type="text" name="machine[module_name]" value={@visual_form["module_name"]} class="app-input w-full" />
        </label>

        <label class="space-y-2 xl:col-span-3">
          <span class="app-field-label">Meaning</span>
          <input type="text" name="machine[meaning]" value={@visual_form["meaning"]} class="app-input w-full" />
        </label>
      </section>

      <div class="grid gap-4 2xl:grid-cols-2">
        <.named_section title="Requests" count_field="request_count" rows={@visual_form["requests"]} row_name="request" />
        <.named_section title="Events" count_field="event_count" rows={@visual_form["events"]} row_name="event" />
        <.named_section title="Commands" count_field="command_count" rows={@visual_form["commands"]} row_name="command" />
        <.named_section title="Signals" count_field="signal_count" rows={@visual_form["signals"]} row_name="signal" />
        <.dependency_section rows={@visual_form["dependencies"]} count_field="dependency_count" />
        <.states_section rows={@visual_form["states"]} count_field="state_count" />
      </div>

      <.transitions_section rows={@visual_form["transitions"]} count_field="transition_count" />
    </form>
    """
  end

  defp visual_unavailable(assigns) do
    ~H"""
    <div class="h-full w-full rounded-2xl border border-dashed border-[var(--app-border)] bg-[var(--app-surface-alt)] px-5 py-5">
      <p class="app-kicker">Visual editor unavailable</p>
      <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
        This machine source currently uses features outside the managed visual subset. Continue editing in Source mode until it returns to the supported shape.
      </p>
    </div>
    """
  end

  attr(:draft_source, :string, required: true)

  defp source_editor(assigns) do
    ~H"""
    <form phx-change="change_source" class="grid h-full w-full">
      <textarea
        name="draft[source]"
        class="app-textarea h-full w-full font-mono text-[13px] leading-6"
      ><%= @draft_source %></textarea>
    </form>
    """
  end

  attr(:title, :string, required: true)
  attr(:count_field, :string, required: true)
  attr(:rows, :map, required: true)
  attr(:row_name, :string, required: true)

  defp named_section(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex items-end justify-between gap-3">
        <div>
          <p class="app-kicker">{@title}</p>
        </div>
        <label class="space-y-1 text-right">
          <span class="app-field-label">Count</span>
          <input
            type="number"
            min="0"
            max="16"
            name={"machine[#{@count_field}]"}
            value={map_size(@rows)}
            class="app-input w-20"
          />
        </label>
      </div>

      <div class="mt-4 space-y-3">
        <div :for={{key, row} <- ordered_entries(@rows)} class="grid gap-3">
          <label class="space-y-2">
            <span class="app-field-label">{String.capitalize(@row_name)} {String.to_integer(key) + 1}</span>
            <input type="text" name={"machine[#{@row_name}s][#{key}][name]"} value={row["name"]} class="app-input w-full" />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Meaning</span>
            <input
              type="text"
              name={"machine[#{@row_name}s][#{key}][meaning]"}
              value={row["meaning"]}
              class="app-input w-full"
            />
          </label>
        </div>
      </div>
    </section>
    """
  end

  attr(:rows, :map, required: true)
  attr(:count_field, :string, required: true)

  defp dependency_section(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex items-end justify-between gap-3">
        <p class="app-kicker">Dependencies</p>
        <label class="space-y-1 text-right">
          <span class="app-field-label">Count</span>
          <input
            type="number"
            min="0"
            max="16"
            name={"machine[#{@count_field}]"}
            value={map_size(@rows)}
            class="app-input w-20"
          />
        </label>
      </div>

      <div class="mt-4 space-y-3">
        <div
          :for={{key, row} <- ordered_entries(@rows)}
          class="grid gap-3 xl:grid-cols-2"
        >
          <label class="space-y-2">
            <span class="app-field-label">Dependency {String.to_integer(key) + 1}</span>
            <input
              type="text"
              name={"machine[dependencies][#{key}][name]"}
              value={row["name"]}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Meaning</span>
            <input
              type="text"
              name={"machine[dependencies][#{key}][meaning]"}
              value={row["meaning"]}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Skills</span>
            <input
              type="text"
              name={"machine[dependencies][#{key}][skills]"}
              value={row["skills"]}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Signals</span>
            <input
              type="text"
              name={"machine[dependencies][#{key}][signals]"}
              value={row["signals"]}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2 xl:col-span-2">
            <span class="app-field-label">Status</span>
            <input
              type="text"
              name={"machine[dependencies][#{key}][status]"}
              value={row["status"]}
              class="app-input w-full"
            />
          </label>
        </div>
      </div>
    </section>
    """
  end

  attr(:rows, :map, required: true)
  attr(:count_field, :string, required: true)

  defp states_section(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex items-end justify-between gap-3">
        <p class="app-kicker">States</p>
        <label class="space-y-1 text-right">
          <span class="app-field-label">Count</span>
          <input type="number" min="1" max="16" name={"machine[#{@count_field}]"} value={map_size(@rows)} class="app-input w-20" />
        </label>
      </div>

      <div class="mt-4 space-y-3">
        <div :for={{key, row} <- ordered_entries(@rows)} class="grid gap-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto]">
          <label class="space-y-2">
            <span class="app-field-label">Name</span>
            <input type="text" name={"machine[states][#{key}][name]"} value={row["name"]} class="app-input w-full" />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Status</span>
            <input type="text" name={"machine[states][#{key}][status]"} value={row["status"]} class="app-input w-full" />
          </label>

          <label class="mt-7 flex items-center gap-2 text-sm text-[var(--app-text-muted)]">
            <input type="hidden" name={"machine[states][#{key}][initial?]"} value="false" />
            <input type="checkbox" name={"machine[states][#{key}][initial?]"} value="true" checked={row["initial?"] == "true"} class="size-4 rounded border-[var(--app-border)]" />
            Initial
          </label>

          <label class="space-y-2 md:col-span-3">
            <span class="app-field-label">Meaning</span>
            <input type="text" name={"machine[states][#{key}][meaning]"} value={row["meaning"]} class="app-input w-full" />
          </label>
        </div>
      </div>
    </section>
    """
  end

  attr(:rows, :map, required: true)
  attr(:count_field, :string, required: true)

  defp transitions_section(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex items-end justify-between gap-3">
        <p class="app-kicker">Transitions</p>
        <label class="space-y-1 text-right">
          <span class="app-field-label">Count</span>
          <input type="number" min="0" max="16" name={"machine[#{@count_field}]"} value={map_size(@rows)} class="app-input w-20" />
        </label>
      </div>

      <div class="mt-4 space-y-3">
        <div :for={{key, row} <- ordered_entries(@rows)} class="grid gap-3 xl:grid-cols-4">
          <label class="space-y-2">
            <span class="app-field-label">Source</span>
            <input type="text" name={"machine[transitions][#{key}][source]"} value={row["source"]} class="app-input w-full" />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Trigger</span>
            <div class="grid grid-cols-[8rem_minmax(0,1fr)] gap-2">
              <select name={"machine[transitions][#{key}][family]"} class="app-select w-full">
                <option value="request" selected={row["family"] == "request"}>request</option>
                <option value="event" selected={row["family"] == "event"}>event</option>
              </select>
              <input type="text" name={"machine[transitions][#{key}][trigger]"} value={row["trigger"]} class="app-input w-full" />
            </div>
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Destination</span>
            <input type="text" name={"machine[transitions][#{key}][destination]"} value={row["destination"]} class="app-input w-full" />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Meaning</span>
            <input type="text" name={"machine[transitions][#{key}][meaning]"} value={row["meaning"]} class="app-input w-full" />
          </label>
        </div>
      </div>
    </section>
    """
  end

  defp ordered_entries(rows) do
    Enum.sort_by(rows, fn {key, _value} -> String.to_integer(key) end)
  end
end
