defmodule Ogol.HMIWeb.MachineStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMIWeb.Components.{StudioCell, StudioLibrary}
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell
  alias Ogol.Studio.MachineCell
  alias Ogol.Studio.MachineDefinition
  alias Ogol.Studio.MachineDraftStore
  alias Ogol.Studio.Modules

  @views [:visual, :source]

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
     |> assign(:requested_view, :visual)
     |> assign(:machine_issue, nil)
     |> load_machine(MachineDraftStore.default_id())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_machine(socket, params["machine_id"] || MachineDraftStore.default_id())}
  end

  @impl true
  def handle_event("select_view", %{"view" => view}, socket) do
    view =
      view
      |> String.to_existing_atom()
      |> then(fn view -> if view in @views, do: view, else: :source end)

    {:noreply, assign(socket, :requested_view, view)}
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
         |> assign(:current_source_digest, Build.digest(source))
         |> assign(:sync_state, :synced)
         |> assign(:sync_diagnostics, [])
         |> assign(:validation_errors, [])
         |> assign(:machine_issue, nil)
         |> assign(:runtime_status, current_runtime_status(source, model))}

      {:error, errors} ->
        {:noreply,
         socket
         |> assign(:visual_form, visual_form)
         |> assign(:validation_errors, errors)
         |> assign(:machine_issue, nil)}
    end
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    {model, sync_state, diagnostics} =
      case MachineDefinition.from_source(source) do
        {:ok, model} ->
          {model, :synced, []}

        {:error, diagnostics} ->
          {nil, :unsupported, diagnostics}
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
     |> assign(:current_source_digest, Build.digest(source))
     |> assign(
       :visual_form,
       (model && MachineDefinition.form_from_model(model)) || socket.assigns.visual_form
     )
     |> assign(:sync_state, sync_state)
     |> assign(:sync_diagnostics, diagnostics)
     |> assign(:validation_errors, [])
     |> assign(:machine_issue, nil)
     |> assign(:runtime_status, current_runtime_status(source, model))}
  end

  def handle_event("request_transition", %{"transition" => "build"}, socket) do
    with {:ok, module} <- MachineDefinition.module_from_source(socket.assigns.draft_source),
         runtime_key <- runtime_key(module),
         {:ok, artifact} <-
           Build.build(runtime_key, module, socket.assigns.draft_source) do
      draft =
        MachineDraftStore.record_build(socket.assigns.machine_id, artifact, artifact.diagnostics)

      {:noreply,
       socket
       |> assign(:machine_draft, draft)
       |> assign(
         :runtime_status,
         current_runtime_status(socket.assigns.draft_source, socket.assigns.machine_model)
       )
       |> assign(:machine_issue, nil)}
    else
      {:error, %{diagnostics: diagnostics}} ->
        draft = MachineDraftStore.record_build(socket.assigns.machine_id, nil, diagnostics)

        {:noreply,
         socket
         |> assign(:machine_draft, draft)
         |> assign(:machine_issue, nil)}

      {:error, :module_not_found} ->
        {:noreply,
         assign(
           socket,
           :machine_issue,
           {:build_missing_module,
            "Source must define one machine module before it can be built."}
         )}
    end
  end

  def handle_event("request_transition", %{"transition" => "apply"}, socket) do
    case socket.assigns.machine_draft.build_artifact do
      nil ->
        {:noreply,
         assign(
           socket,
           :machine_issue,
           {:apply_without_build, "Build a valid artifact before applying it."}
         )}

      artifact ->
        case Modules.apply(artifact.id, artifact) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> assign(
               :runtime_status,
               current_runtime_status(socket.assigns.draft_source, socket.assigns.machine_model)
             )
             |> assign(:machine_issue, nil)}

          {:blocked, %{pids: _pids}} ->
            {:noreply,
             socket
             |> assign(
               :runtime_status,
               current_runtime_status(socket.assigns.draft_source, socket.assigns.machine_model)
             )
             |> assign(:machine_issue, nil)}

          {:error, {:module_mismatch, _expected, _actual}} ->
            {:noreply,
             socket
             |> assign(
               :runtime_status,
               current_runtime_status(socket.assigns.draft_source, socket.assigns.machine_model)
             )
             |> assign(:machine_issue, nil)}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(
               :runtime_status,
               current_runtime_status(socket.assigns.draft_source, socket.assigns.machine_model)
             )
             |> assign(:machine_issue, nil)}
        end
    end
  end

  @impl true
  def render(assigns) do
    machine_facts = MachineCell.facts_from_assigns(assigns)

    assigns =
      assigns
      |> assign(:machine_cell, Cell.derive(MachineCell, machine_facts))
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
        <:actions>
          <StudioCell.action_button
            :for={action <- @machine_cell.actions}
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
            :for={view <- @machine_cell.views}
            type="button"
            phx-click="select_view"
            phx-value-view={view.id}
            selected={@machine_cell.selected_view == view.id}
            available={view.available?}
            data-test={"machine-view-#{view.id}"}
          >
            {view.label}
          </StudioCell.view_button>
        </:views>

        <:notice :if={@machine_cell.notice}>
          <StudioCell.notice
            tone={@machine_cell.notice.tone}
            title={@machine_cell.notice.title}
            message={@machine_cell.notice.message}
          />
        </:notice>

        <:body>
          <.visual_editor
            :if={@machine_cell.selected_view == :visual}
            visual_form={@visual_form}
          />

          <.source_editor :if={@machine_cell.selected_view == :source} draft_source={@draft_source} />
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
    |> assign(:current_source_digest, Build.digest(draft.source))
    |> assign(:sync_state, draft.sync_state)
    |> assign(:sync_diagnostics, draft.sync_diagnostics)
    |> assign(:validation_errors, [])
    |> assign(:machine_issue, nil)
    |> assign(:runtime_status, current_runtime_status(draft.source, model))
  end

  defp current_runtime_status(source, model) do
    with {:ok, module} <- current_runtime_module(source, model),
         {:ok, status} <- Modules.status(runtime_key(module)) do
      status
    else
      _ -> MachineCell.default_runtime_status()
    end
  end

  defp current_runtime_module(_source, %{module_name: module_name}) when is_binary(module_name) do
    {:ok, MachineDefinition.module_from_name!(module_name)}
  end

  defp current_runtime_module(source, _model) when is_binary(source) do
    MachineDefinition.module_from_source(source)
  end

  defp runtime_key(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
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

  defp humanize_sync_state(:synced), do: "Synced"
  defp humanize_sync_state(:unsupported), do: "Source-only"
  defp humanize_sync_state(other), do: other |> to_string() |> String.capitalize()

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
