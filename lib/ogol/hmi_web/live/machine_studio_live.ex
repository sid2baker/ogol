defmodule Ogol.HMIWeb.MachineStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMIWeb.Components.{StudioCell, StudioLibrary}
  alias Ogol.HMIWeb.StudioRevision
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell
  alias Ogol.Studio.MachineCell
  alias Ogol.Studio.Modules
  alias Ogol.Studio.WorkspaceStore

  @views [:visual, :source]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Machine Studio")
     |> assign(
       :page_summary,
       "Author canonical machine modules from a constrained visual subset or edit the source directly, then compile them into the selected runtime."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :machines)
     |> assign(:requested_view, :visual)
     |> assign(:machine_issue, nil)
     |> StudioRevision.subscribe()
     |> load_machine(nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = StudioRevision.apply_param(socket, params)
    {:noreply, load_machine(socket, params["machine_id"])}
  end

  @impl true
  def handle_info({:workspace_updated, _operation, _reply, _session}, socket) do
    {:noreply,
     socket
     |> StudioRevision.sync_session()
     |> load_machine(socket.assigns[:machine_id])}
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
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_machine(socket)}
    else
      draft = WorkspaceStore.create_machine()
      {:noreply, push_patch(socket, to: ~p"/studio/machines/#{draft.id}")}
    end
  end

  def handle_event("change_visual", %{"machine" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_machine(socket)}
    else
      visual_form = normalize_visual_form(params, socket.assigns.visual_form)

      case MachineSource.cast_model(visual_form) do
        {:ok, model} ->
          source = MachineSource.to_source(model)

          draft =
            WorkspaceStore.save_machine_source(
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
           |> assign(:visual_form, MachineSource.form_from_model(model))
           |> assign(:draft_source, source)
           |> assign(:current_source_digest, Build.digest(source))
           |> assign(:sync_state, :synced)
           |> assign(:sync_diagnostics, [])
           |> assign(:validation_errors, [])
           |> assign(:machine_issue, nil)
           |> assign(:runtime_status, current_runtime_status(socket.assigns.machine_id))}

        {:error, errors} ->
          {:noreply,
           socket
           |> assign(:visual_form, visual_form)
           |> assign(:validation_errors, errors)
           |> assign(:machine_issue, nil)}
      end
    end
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_machine(socket)}
    else
      {model, sync_state, diagnostics} =
        case MachineSource.from_source(source) do
          {:ok, model} ->
            {model, :synced, []}

          {:error, diagnostics} ->
            {nil, :unsupported, diagnostics}
        end

      draft =
        WorkspaceStore.save_machine_source(
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
         (model && MachineSource.form_from_model(model)) || socket.assigns.visual_form
       )
       |> assign(:sync_state, sync_state)
       |> assign(:sync_diagnostics, diagnostics)
       |> assign(:validation_errors, [])
       |> assign(:machine_issue, nil)
       |> assign(:runtime_status, current_runtime_status(socket.assigns.machine_id))}
    end
  end

  def handle_event("request_transition", %{"transition" => "compile"}, socket) do
    case WorkspaceStore.compile_machine(socket.assigns.machine_id) do
      {:ok, draft} ->
        {:noreply,
         socket
         |> assign(:machine_draft, draft)
         |> assign(:runtime_status, current_runtime_status(socket.assigns.machine_id))
         |> assign(:machine_issue, nil)}

      {:error, diagnostics, draft} when is_list(diagnostics) ->
        {:noreply,
         socket
         |> assign(:machine_draft, draft)
         |> assign(:runtime_status, current_runtime_status(socket.assigns.machine_id))
         |> assign(:machine_issue, nil)}

      {:error, :module_not_found, _draft} ->
        {:noreply,
         assign(
           socket,
           :machine_issue,
           {:compile_missing_module,
            "Source must define one machine module before it can be compiled."}
         )}
    end
  end

  @impl true
  def render(assigns) do
    machine_facts = MachineCell.facts_from_assigns(assigns)

    assigns =
      assigns
      |> assign(:machine_cell, Cell.derive(MachineCell, machine_facts))
      |> assign(
        :machine_items,
        machine_items(
          assigns.machine_library,
          assigns.machine_id,
          assigns.studio_selected_revision
        )
      )

    ~H"""
    <section class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
      <StudioLibrary.list title="Machines" items={@machine_items} current_id={@machine_id}>
        <:actions>
          <button
            type="button"
            phx-click="new_machine"
            class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
            disabled={@studio_read_only?}
            title={if(@studio_read_only?, do: StudioRevision.readonly_message())}
          >
            New
          </button>
        </:actions>
      </StudioLibrary.list>

      <StudioCell.cell :if={@machine_draft} body_class="min-h-[72rem]">
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
            read_only?={@studio_read_only?}
          />

          <.source_editor
            :if={@machine_cell.selected_view == :source}
            draft_source={@draft_source}
            read_only?={@studio_read_only?}
          />
        </:body>
      </StudioCell.cell>

      <section :if={!@machine_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Machines</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          The current bundle does not contain any machines
        </h2>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          Import a bundle that includes machines, or create a new machine in Draft mode.
        </p>
      </section>
    </section>
    """
  end

  defp load_machine(socket, machine_id) do
    {resolved_machine_id, draft, library} = machine_snapshot(socket.assigns, machine_id)

    if draft do
      model =
        draft.model ||
          case MachineSource.from_source(draft.source) do
            {:ok, model} -> model
            {:error, _diagnostics} -> nil
          end

      socket
      |> assign(:machine_id, resolved_machine_id)
      |> assign(:machine_draft, draft)
      |> assign(:machine_library, library)
      |> assign(:machine_model, model)
      |> assign(
        :visual_form,
        (model && MachineSource.form_from_model(model)) ||
          MachineSource.form_from_model(MachineSource.default_model(resolved_machine_id))
      )
      |> assign(:draft_source, draft.source)
      |> assign(:current_source_digest, Build.digest(draft.source))
      |> assign(:sync_state, draft.sync_state)
      |> assign(:sync_diagnostics, draft.sync_diagnostics)
      |> assign(:validation_errors, [])
      |> assign(:machine_issue, nil)
      |> assign(:runtime_status, current_runtime_status(resolved_machine_id))
    else
      socket
      |> assign(:machine_id, nil)
      |> assign(:machine_draft, nil)
      |> assign(:machine_library, library)
      |> assign(:machine_model, nil)
      |> assign(
        :visual_form,
        MachineSource.form_from_model(MachineSource.default_model("machine"))
      )
      |> assign(:draft_source, "")
      |> assign(:current_source_digest, Build.digest(""))
      |> assign(:sync_state, :synced)
      |> assign(:sync_diagnostics, [])
      |> assign(:validation_errors, [])
      |> assign(:machine_issue, nil)
      |> assign(:runtime_status, MachineCell.default_runtime_status())
    end
  end

  defp machine_snapshot(_assigns, requested_id) do
    drafts = WorkspaceStore.list_machines()
    draft = select_machine_draft(drafts, requested_id)
    {draft && draft.id, draft, drafts}
  end

  defp select_machine_draft(drafts, requested_id) do
    Enum.find(drafts, &(&1.id == requested_id)) ||
      Enum.find(drafts, &(&1.id == WorkspaceStore.machine_default_id())) ||
      List.first(drafts)
  end

  defp current_runtime_status(machine_id) when is_binary(machine_id) do
    with {:ok, status} <- Modules.status(Modules.runtime_id(:machine, machine_id)) do
      status
    else
      _ -> MachineCell.default_runtime_status()
    end
  end

  defp machine_items(drafts, current_id, selected_revision) do
    Enum.map(drafts, fn draft ->
      %{
        id: draft.id,
        label: machine_label(draft),
        detail: machine_detail(draft),
        path:
          StudioRevision.path_with_revision(~p"/studio/machines/#{draft.id}", selected_revision),
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

  defp machine_detail(%{model: model}) when is_map(model), do: MachineSource.summary(model)
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
  attr(:read_only?, :boolean, default: false)

  defp visual_editor(assigns) do
    ~H"""
    <form phx-change="change_visual" class="grid h-full w-full content-start gap-5">
      <fieldset disabled={@read_only?} class="contents">
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

      <section class="grid gap-4">
        <div>
          <p class="app-kicker">Interface</p>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
            Configure what operators, HMIs, and topologies can ask of this machine and what this machine emits publicly.
          </p>
        </div>

        <div class="grid gap-4 2xl:grid-cols-2">
          <.named_section
            title="Request Skills"
            hint="Synchronous public skills. A handled request must reply exactly once."
            count_field="request_count"
            rows={@visual_form["requests"]}
            row_name="request"
          />

          <.named_section
            title="Event Skills"
            hint="Asynchronous public skills. These are accepted fire-and-forget events."
            count_field="event_count"
            rows={@visual_form["events"]}
            row_name="event"
          />

          <.named_section
            title="Public Signals"
            hint="Outbound notifications this machine emits when notable things happen."
            count_field="signal_count"
            rows={@visual_form["signals"]}
            row_name="signal"
          />

          <.status_interface_note />
        </div>
      </section>

      <section class="grid gap-4">
        <div>
          <p class="app-kicker">Dependencies</p>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
            Declare the dependency contract this machine expects from other machines: invokable skills, observable signals, and readable status.
          </p>
        </div>

        <.dependency_section rows={@visual_form["dependencies"]} count_field="dependency_count" />
      </section>

      <section class="grid gap-4">
        <div>
          <p class="app-kicker">Behavior</p>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
            Define how the machine behaves internally: hardware-facing commands, control states, and the transitions between them.
          </p>
        </div>

        <div class="grid gap-4 2xl:grid-cols-2">
          <.named_section
            title="Commands"
            hint="Outbound hardware commands this machine may dispatch."
            count_field="command_count"
            rows={@visual_form["commands"]}
            row_name="command"
          />

          <.states_section rows={@visual_form["states"]} count_field="state_count" />
        </div>

        <.transitions_section rows={@visual_form["transitions"]} count_field="transition_count" />
      </section>
      </fieldset>
    </form>
    """
  end

  attr(:draft_source, :string, required: true)
  attr(:read_only?, :boolean, default: false)

  defp source_editor(assigns) do
    ~H"""
    <form phx-change="change_source" class="grid h-full w-full">
      <fieldset disabled={@read_only?} class="contents">
      <textarea
        name="draft[source]"
        class="app-textarea h-full w-full font-mono text-[13px] leading-6"
      ><%= @draft_source %></textarea>
      </fieldset>
    </form>
    """
  end

  attr(:title, :string, required: true)
  attr(:hint, :string, default: nil)
  attr(:count_field, :string, required: true)
  attr(:rows, :map, required: true)
  attr(:row_name, :string, required: true)

  defp named_section(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex items-end justify-between gap-3">
        <div>
          <p class="app-kicker">{@title}</p>
          <p :if={@hint} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">{@hint}</p>
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

  defp status_interface_note(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <p class="app-kicker">Public Status</p>
      <div class="mt-3 space-y-3 text-sm leading-6 text-[var(--app-text-muted)]">
        <p>Every machine exposes runtime status such as <code>current_state</code> and health.</p>
        <p>
          In the visual subset, the public wording for each control mode is configured in the
          <strong>States and Status</strong> section below.
        </p>
        <p>
          Additional public facts, outputs, or fields still require <strong>Source</strong>, because they
          need data definitions and update behavior beyond this constrained editor.
        </p>
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
          class="rounded-2xl border border-[var(--app-border)]/80 bg-[var(--app-surface)] px-4 py-4"
        >
          <div class="grid gap-3 xl:grid-cols-2">
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
          </div>

          <div class="mt-4 grid gap-4 xl:grid-cols-3">
            <.dependency_contract_section
              title="Skills"
              hint="Public dependency skills this machine may invoke."
              count_name={"machine[dependencies][#{key}][skill_count]"}
              rows={row["skills"] || %{}}
              field_name={"machine[dependencies][#{key}][skills]"}
            />

            <.dependency_contract_section
              title="Signals"
              hint="Dependency signals this machine may observe through topology wiring."
              count_name={"machine[dependencies][#{key}][signal_count]"}
              rows={row["signals"] || %{}}
              field_name={"machine[dependencies][#{key}][signals]"}
            />

            <.dependency_contract_section
              title="Status"
              hint="Public status items this machine may observe from the dependency."
              count_name={"machine[dependencies][#{key}][status_count]"}
              rows={row["status"] || %{}}
              field_name={"machine[dependencies][#{key}][status]"}
            />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:hint, :string, required: true)
  attr(:count_name, :string, required: true)
  attr(:rows, :map, required: true)
  attr(:field_name, :string, required: true)

  defp dependency_contract_section(assigns) do
    ~H"""
    <section class="rounded-xl border border-[var(--app-border)]/70 bg-[var(--app-surface-alt)] px-3 py-3">
      <div class="flex items-end justify-between gap-3">
        <div>
          <p class="app-field-label">{@title}</p>
          <p class="mt-1 text-xs text-[var(--app-text-muted)]">{@hint}</p>
        </div>

        <label class="space-y-1 text-right">
          <span class="app-field-label">Count</span>
          <input
            type="number"
            min="0"
            max="16"
            name={@count_name}
            value={map_size(@rows)}
            class="app-input w-20"
          />
        </label>
      </div>

      <div class="mt-3 space-y-3">
        <label :for={{item_key, item} <- ordered_entries(@rows)} class="space-y-2 block">
          <span class="app-field-label">{@title} {String.to_integer(item_key) + 1}</span>
          <input
            type="text"
            name={"#{@field_name}[#{item_key}][name]"}
            value={item["name"]}
            class="app-input w-full"
          />
        </label>
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
        <div>
          <p class="app-kicker">States and Status</p>
          <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            State names define control modes. Status labels describe how those modes surface publicly.
          </p>
        </div>
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
            <span class="app-field-label">Status Label</span>
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

  defp readonly_machine(socket) do
    assign(socket, :machine_issue, {:revision_read_only, StudioRevision.readonly_message()})
  end
end
