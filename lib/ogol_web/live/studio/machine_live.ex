defmodule OgolWeb.Studio.MachineLive do
  use OgolWeb, :live_view

  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Studio.CellPath
  alias OgolWeb.Studio.Library, as: StudioLibrary
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias OgolWeb.Live.SessionAction
  alias OgolWeb.Live.SessionSync
  alias Ogol.Machine.Form, as: MachineForm
  alias Ogol.Machine.Graph, as: MachineGraph
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell, as: StudioCellModel
  alias Ogol.Machine.Studio.Cell, as: MachineCell
  alias Ogol.Session

  @views [:config, :source]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Machine Studio")
     |> assign(
       :page_summary,
       "Author canonical machine modules from a constrained visual subset or edit the source directly, then compile them for topology deployment."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :machines)
     |> assign(:requested_view, :config)
     |> assign(:machine_issue, nil)
     |> StudioRevision.subscribe()
     |> load_machine(nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested_machine_id =
      if socket.assigns.live_action in [:show, :cell], do: params["machine_id"], else: nil

    socket =
      socket
      |> StudioRevision.apply_param(params)
      |> SessionSync.ensure_entry(:machine, requested_machine_id)
      |> assign(:requested_view, requested_machine_view(params["view"]))
      |> load_machine(requested_machine_id)

    {:noreply, maybe_canonicalize_machine_path(socket, requested_machine_id, params["view"])}
  end

  @impl true
  def handle_info({:operations, operations}, socket) do
    machine_issue =
      if Enum.all?(operations, &artifact_runtime_operation?/1) do
        socket.assigns[:machine_issue]
      else
        nil
      end

    {:noreply,
     socket
     |> StudioRevision.apply_operations(operations)
     |> load_machine(socket.assigns[:machine_id])
     |> assign(:machine_issue, machine_issue)}
  end

  @impl true
  def handle_event("select_view", %{"view" => view}, socket) do
    view =
      view
      |> String.to_existing_atom()
      |> then(fn view -> if view in @views, do: view, else: :config end)

    path =
      case socket.assigns.live_action do
        :cell -> CellPath.show_path(:machine, socket.assigns.machine_id, view)
        _other -> CellPath.page_path(:machine, socket.assigns.machine_id, view)
      end

    {:noreply, push_patch(socket, to: path)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("new_machine", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_machine(socket)}
    else
      draft = Session.create_machine()
      {:noreply, push_patch(socket, to: CellPath.page_path(:machine, draft.id, :config))}
    end
  end

  def handle_event("change_visual", %{"machine" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_machine(socket)}
    else
      visual_form = normalize_visual_form(params, socket.assigns.visual_form)

      case MachineForm.cast(visual_form) do
        {:ok, model} ->
          source = MachineSource.to_source(model)

          draft =
            Session.save_machine_source(
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
           |> assign(:machine_graph_model, model)
           |> assign(:machine_projection, config_projection_from_source(source))
           |> assign(:visual_form, MachineForm.to_form(model))
           |> assign(:draft_source, source)
           |> assign(:current_source_digest, Build.digest(source))
           |> assign(:sync_state, :synced)
           |> assign(:sync_diagnostics, [])
           |> assign(:validation_errors, [])
           |> assign(:machine_issue, nil)
           |> assign(:runtime_status, current_runtime_status(socket, socket.assigns.machine_id))
           |> assign_machine_projection()}

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
        Session.save_machine_source(
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
       |> assign(:machine_graph_model, graph_model_from_source(source, model))
       |> assign(:machine_projection, config_projection_from_source(source))
       |> assign(:draft_source, source)
       |> assign(:current_source_digest, Build.digest(source))
       |> assign(
         :visual_form,
         (model && MachineForm.to_form(model)) || socket.assigns.visual_form
       )
       |> assign(:sync_state, sync_state)
       |> assign(:sync_diagnostics, diagnostics)
       |> assign(:validation_errors, [])
       |> assign(:machine_issue, nil)
       |> assign(:runtime_status, current_runtime_status(socket, socket.assigns.machine_id))
       |> assign_machine_projection()}
    end
  end

  def handle_event("request_transition", %{"transition" => transition}, socket)
      when transition in ["compile", "recompile", "delete"] do
    case current_machine_control(socket.assigns, transition) do
      nil ->
        {:noreply, socket}

      %{id: :delete} = control ->
        SessionAction.reduce_control(
          socket,
          control,
          after: fn socket, _reply ->
            socket = SessionSync.refresh(socket)
            push_patch(socket, to: machine_path_after_delete(socket))
          end
        )

      control ->
        SessionAction.reduce_control(socket, control,
          after: &apply_runtime_feedback(&1, control.operation, &2)
        )
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:machine_cell, current_machine_cell(assigns))
      |> assign(
        :machine_items,
        machine_items(
          assigns.machine_library,
          if(assigns.live_action == :show, do: assigns.machine_id, else: nil)
        )
      )

    ~H"""
    <%= if @live_action == :cell do %>
      <.machine_cell_body
        :if={@machine_draft}
        machine_cell={@machine_cell}
        machine_id={@machine_id}
        visual_form={@visual_form}
        draft_source={@draft_source}
        read_only?={@studio_read_only?}
        machine_model={@machine_model}
        machine_projection={@machine_projection}
        sync_state={@sync_state}
        sync_diagnostics={@sync_diagnostics}
        machine_diagram={@machine_diagram}
      />

      <section :if={!@machine_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Machines</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          The current workspace does not contain any machines
        </h2>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          Create a machine from the Machines index page to open it here.
        </p>
      </section>
    <% else %>
      <%= if @live_action == :show do %>
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
                :for={control <- @machine_cell.controls}
                type="button"
                phx-click="request_transition"
                phx-value-transition={control.id}
                variant={control.variant}
                disabled={!control.enabled?}
                title={control.disabled_reason}
              >
                {control.label}
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
              <.machine_cell_body
                machine_cell={@machine_cell}
                machine_id={@machine_id}
                visual_form={@visual_form}
                draft_source={@draft_source}
                read_only?={@studio_read_only?}
                machine_model={@machine_model}
                machine_projection={@machine_projection}
                sync_state={@sync_state}
                sync_diagnostics={@sync_diagnostics}
                machine_diagram={@machine_diagram}
              />
            </:body>
          </StudioCell.cell>

          <section :if={!@machine_draft} class="app-panel px-5 py-5">
            <p class="app-kicker">No Machines</p>
            <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
              The current workspace does not contain any machines
            </h2>
            <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
              Create a machine from the Machines index page to open it here.
            </p>
          </section>
        </section>
      <% else %>
        <section class="grid gap-5">
          <StudioLibrary.list title="Machines" items={@machine_items} current_id={nil}>
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
        </section>
      <% end %>
    <% end %>
    """
  end

  attr(:machine_cell, :map, required: true)
  attr(:machine_id, :string, default: nil)
  attr(:visual_form, :map, required: true)
  attr(:draft_source, :string, required: true)
  attr(:read_only?, :boolean, default: false)
  attr(:machine_model, :map, default: nil)
  attr(:machine_projection, :map, default: nil)
  attr(:sync_state, :atom, default: :synced)
  attr(:sync_diagnostics, :list, default: [])
  attr(:machine_diagram, :string, default: nil)

  defp machine_cell_body(assigns) do
    ~H"""
    <.machine_config_screen
      :if={@machine_cell.selected_view == :config}
      machine_id={@machine_id}
      visual_form={@visual_form}
      draft_source={@draft_source}
      read_only?={@read_only?}
      machine_model={@machine_model}
      machine_projection={@machine_projection}
      sync_state={@sync_state}
      sync_diagnostics={@sync_diagnostics}
      machine_diagram={@machine_diagram}
    />

    <.source_editor
      :if={@machine_cell.selected_view == :source}
      draft_source={@draft_source}
      read_only?={@read_only?}
    />
    """
  end

  defp load_machine(socket, machine_id) do
    {resolved_machine_id, draft, library} = machine_snapshot(socket, machine_id)

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
      |> assign(:machine_graph_model, graph_model_from_source(draft.source, model))
      |> assign(:machine_projection, config_projection_from_source(draft.source))
      |> assign(
        :visual_form,
        (model && MachineForm.to_form(model)) ||
          MachineForm.to_form(MachineForm.default_model(resolved_machine_id))
      )
      |> assign(:draft_source, draft.source)
      |> assign(:current_source_digest, Build.digest(draft.source))
      |> assign(:sync_state, draft.sync_state)
      |> assign(:sync_diagnostics, draft.sync_diagnostics)
      |> assign(:validation_errors, [])
      |> assign(:machine_issue, nil)
      |> assign(:runtime_status, current_runtime_status(socket, resolved_machine_id))
      |> assign_machine_projection()
    else
      socket
      |> assign(:machine_id, nil)
      |> assign(:machine_draft, nil)
      |> assign(:machine_library, library)
      |> assign(:machine_model, nil)
      |> assign(:machine_graph_model, nil)
      |> assign(:machine_projection, nil)
      |> assign(
        :visual_form,
        MachineForm.to_form(MachineForm.default_model("machine"))
      )
      |> assign(:draft_source, "")
      |> assign(:current_source_digest, Build.digest(""))
      |> assign(:sync_state, :synced)
      |> assign(:sync_diagnostics, [])
      |> assign(:validation_errors, [])
      |> assign(:machine_issue, nil)
      |> assign(:runtime_status, MachineCell.default_runtime_status())
      |> assign_machine_projection()
    end
  end

  defp machine_snapshot(socket, requested_id) do
    drafts = SessionSync.list_entries(socket, :machine)
    draft = select_machine_draft(drafts, requested_id)
    {draft && draft.id, draft, drafts}
  end

  defp select_machine_draft(drafts, requested_id) do
    Enum.find(drafts, &(&1.id == requested_id)) ||
      List.first(Enum.sort_by(drafts, & &1.id))
  end

  defp current_runtime_status(source, machine_id) when is_binary(machine_id) do
    SessionSync.runtime_artifact_status(source, :machine, machine_id) ||
      MachineCell.default_runtime_status()
  end

  defp current_machine_cell(assigns) do
    assigns
    |> MachineCell.facts_from_assigns()
    |> then(&StudioCellModel.derive(MachineCell, &1))
  end

  defp current_machine_control(assigns, transition) do
    assigns
    |> current_machine_cell()
    |> StudioCellModel.control_for_transition(transition)
  end

  defp artifact_runtime_operation?({:replace_artifact_runtime, statuses}) when is_list(statuses),
    do: true

  defp artifact_runtime_operation?(_operation), do: false

  defp apply_runtime_feedback(
         socket,
         {:compile_artifact, :machine, id},
         {:error, :module_not_found}
       ) do
    if socket.assigns[:machine_id] == id do
      assign(
        socket,
        :machine_issue,
        {:compile_missing_module,
         "Source must define one machine module before it can be compiled."}
      )
    else
      socket
    end
  end

  defp apply_runtime_feedback(socket, {:compile_artifact, :machine, id}, _reply) do
    if socket.assigns[:machine_id] == id do
      socket
      |> assign(:machine_issue, nil)
      |> assign_machine_projection()
    else
      socket
    end
  end

  defp apply_runtime_feedback(socket, _action, _reply), do: socket

  defp machine_path_after_delete(socket) do
    case SessionSync.list_entries(socket, :machine) do
      [%{id: id} | _rest] ->
        case socket.assigns.live_action do
          :cell -> CellPath.show_path(:machine, id, :config)
          _other -> CellPath.page_path(:machine, id, :config)
        end

      [] ->
        CellPath.section_path(:machine)
    end
  end

  defp machine_items(drafts, current_id) do
    Enum.map(drafts, fn draft ->
      %{
        id: draft.id,
        label: machine_label(draft),
        detail: machine_detail(draft),
        path: CellPath.page_path(:machine, draft.id, :config),
        status:
          if(draft.id == current_id, do: "open", else: humanize_sync_state(draft.sync_state))
      }
    end)
  end

  defp requested_machine_view(nil), do: :config
  defp requested_machine_view(""), do: :config
  defp requested_machine_view("config"), do: :config
  defp requested_machine_view("source"), do: :source
  defp requested_machine_view("code"), do: :source
  defp requested_machine_view(_other), do: :config

  defp maybe_canonicalize_machine_path(socket, _requested_machine_id, _requested_view)
       when socket.assigns.live_action not in [:show, :cell],
       do: socket

  defp maybe_canonicalize_machine_path(
         %{assigns: %{machine_id: nil}} = socket,
         _requested_machine_id,
         _requested_view
       ),
       do: socket

  defp maybe_canonicalize_machine_path(socket, requested_machine_id, requested_view) do
    selected_view = current_machine_cell(socket.assigns).selected_view

    canonical_path =
      case socket.assigns.live_action do
        :cell -> CellPath.show_path(:machine, socket.assigns.machine_id, selected_view)
        _other -> CellPath.page_path(:machine, socket.assigns.machine_id, selected_view)
      end

    if socket.assigns.machine_id == requested_machine_id and
         (is_nil(requested_view) or requested_view == Atom.to_string(selected_view)) do
      socket
    else
      push_patch(socket, to: canonical_path)
    end
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
            Configure what operators, HMIs, and sequences can ask of this machine and what this machine emits publicly.
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

  attr(:machine_id, :string, default: nil)
  attr(:visual_form, :map, required: true)
  attr(:draft_source, :string, required: true)
  attr(:read_only?, :boolean, default: false)
  attr(:machine_model, :map, default: nil)
  attr(:machine_projection, :map, default: nil)
  attr(:sync_state, :atom, default: :synced)
  attr(:sync_diagnostics, :list, default: [])
  attr(:machine_diagram, :string, default: nil)

  defp machine_config_screen(assigns) do
    ~H"""
    <div class="space-y-5">
      <.machine_graph_panel
        machine_id={@machine_id}
        machine_model={@machine_projection || @machine_model}
        machine_diagram={@machine_diagram}
      />

      <div class="grid gap-5 2xl:grid-cols-[minmax(0,1.15fr)_minmax(22rem,0.85fr)]">
        <div class="min-w-0 space-y-4">
        <.machine_source_only_panel
          :if={@sync_state == :unsupported}
          sync_diagnostics={@sync_diagnostics}
        />

        <.visual_editor
          :if={not is_nil(@machine_model)}
          visual_form={@visual_form}
          read_only?={@read_only?}
        />

        <.machine_config_projection_panel
          :if={is_nil(@machine_model)}
          machine={@machine_projection}
        />

        <.machine_contract_panel :if={@machine_projection} machine={@machine_projection} />
        </div>

        <aside class="space-y-4">
          <.machine_structure_panel :if={@machine_projection} machine={@machine_projection} />
        </aside>
      </div>
    </div>
    """
  end

  attr(:machine_id, :string, default: nil)
  attr(:machine_model, :map, default: nil)
  attr(:machine_diagram, :string, default: nil)

  defp machine_graph_panel(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div :if={@machine_diagram} class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] p-3">
        <div
          id={"machine-mermaid-#{@machine_id || "draft"}"}
          phx-hook="MermaidDiagram"
          phx-update="ignore"
          data-diagram={@machine_diagram}
          class="machine-mermaid min-h-[16rem]"
        >
        </div>
      </div>

      <div :if={is_nil(@machine_diagram)} class="rounded-xl border border-dashed border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-6 text-sm text-[var(--app-text-muted)]">
        Parse the machine into the supported model to render the graph here.
      </div>

      <div :if={@machine_model} class="mt-4 grid gap-3 sm:grid-cols-2">
        <.metric_card
          label="States"
          value={Integer.to_string(length(Map.get(@machine_model, :states, [])))}
        />
        <.metric_card
          label="Transitions"
          value={Integer.to_string(length(Map.get(@machine_model, :transitions, [])))}
        />
      </div>
    </section>
    """
  end

  attr(:sync_diagnostics, :list, default: [])

  defp machine_source_only_panel(assigns) do
    ~H"""
    <section class="rounded-2xl border border-amber-400/30 bg-amber-400/10 px-4 py-4">
      <p class="app-kicker">Config Projection</p>
      <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
        Source uses features outside the first editor
      </h3>
      <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
        Config still shows the parts we can recover directly from source. Use Code view for full
        editing of callbacks, runtime-family triggers, safety, helper functions, and other
        inspect-only features.
      </p>

      <ul :if={@sync_diagnostics != []} class="mt-4 space-y-2 text-sm text-[var(--app-text)]">
        <li :for={diagnostic <- @sync_diagnostics} class="rounded-xl border border-amber-400/30 bg-[var(--app-surface)] px-3 py-2">
          {diagnostic}
        </li>
      </ul>
    </section>
    """
  end

  attr(:machine, :map, required: true)

  defp machine_config_projection_panel(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <p class="app-kicker">Machine</p>
      <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
        {@machine.meaning || humanize_machine_id(@machine.machine_id)}
      </h3>
      <p class="mt-2 font-mono text-xs text-[var(--app-text-dim)]">
        {@machine.module_name}
      </p>

      <p :if={present_text?(@machine.meaning)} class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
        {@machine.meaning}
      </p>

      <dl class="mt-4 grid gap-3 text-sm sm:grid-cols-2">
        <div class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-3">
          <dt class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Machine Id</dt>
          <dd class="mt-1 font-semibold text-[var(--app-text)]">{@machine.machine_id}</dd>
        </div>
        <div class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-3">
          <dt class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">Editor Compatibility</dt>
          <dd class="mt-1 font-semibold text-[var(--app-text)]">{compatibility_label(@machine.compatibility)}</dd>
        </div>
      </dl>

      <div class="mt-4 grid gap-3 sm:grid-cols-3">
        <.metric_card label="Requests" value={Integer.to_string(length(@machine.requests))} />
        <.metric_card label="Events" value={Integer.to_string(length(@machine.events))} />
        <.metric_card label="Commands" value={Integer.to_string(length(@machine.commands))} />
        <.metric_card label="Signals" value={Integer.to_string(length(@machine.signals))} />
        <.metric_card label="Facts" value={Integer.to_string(length(@machine.facts))} />
        <.metric_card label="Outputs" value={Integer.to_string(length(@machine.outputs))} />
      </div>
    </section>
    """
  end

  attr(:machine, :map, required: true)

  defp machine_contract_panel(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <p class="app-kicker">Contract</p>
      <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
        Public contract surface
      </h3>
      <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
        Config shows the contract recovered from source, including public skills, signals, facts,
        and outputs.
      </p>

      <div class="mt-4 grid gap-4 xl:grid-cols-2">
        <.boundary_projection_panel title="Requests" rows={@machine.requests} empty="No request skills declared." />
        <.boundary_projection_panel title="Events" rows={@machine.events} empty="No event skills declared." />
        <.boundary_projection_panel title="Commands" rows={@machine.commands} empty="No commands declared." />
        <.boundary_projection_panel title="Signals" rows={@machine.signals} empty="No signals declared." />
        <.boundary_projection_panel title="Facts" rows={@machine.facts} empty="No facts declared." />
        <.boundary_projection_panel title="Outputs" rows={@machine.outputs} empty="No outputs declared." />
      </div>

    </section>
    """
  end

  attr(:machine, :map, required: true)

  defp machine_structure_panel(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <p class="app-kicker">Structure</p>
      <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
        States, transitions, and memory
      </h3>

      <div class="mt-4 space-y-4">
        <.state_projection_panel states={@machine.states} />
        <.transition_projection_panel transitions={@machine.transitions} />
        <.memory_projection_panel rows={@machine.memory_fields} />
      </div>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)
  attr(:empty, :string, required: true)

  defp boundary_projection_panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
      <div class="flex items-center justify-between gap-3">
        <p class="app-field-label">{@title}</p>
        <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
          {length(@rows)}
        </span>
      </div>

      <div :if={@rows == []} class="mt-3 text-sm text-[var(--app-text-muted)]">
        {@empty}
      </div>

      <div :if={@rows != []} class="mt-3 space-y-3">
        <div :for={row <- @rows} class="rounded-xl border border-[var(--app-border)]/70 bg-[var(--app-surface-alt)] px-3 py-3">
          <div class="flex flex-wrap items-center gap-2">
            <p class="text-sm font-semibold text-[var(--app-text)]">{row.name}</p>
            <span
              :if={row[:kind]}
              class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]"
            >
              {row.kind}
            </span>
            <span
              :if={is_boolean(row[:skill?])}
              class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]"
            >
              {if row[:skill?], do: "skill", else: "internal"}
            </span>
            <span
              :if={is_boolean(row[:public?])}
              class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]"
            >
              {if row[:public?], do: "public", else: "private"}
            </span>
          </div>

          <p :if={present_text?(row[:meaning])} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            {row.meaning}
          </p>

          <dl
            :if={not is_nil(row[:type]) or not is_nil(row[:default])}
            class="mt-3 grid gap-2 text-xs text-[var(--app-text-muted)]"
          >
            <div :if={not is_nil(row[:type])}>
              <dt class="font-mono uppercase tracking-[0.14em] text-[var(--app-text-dim)]">Type</dt>
              <dd class="mt-1 font-mono">{inspect(row.type)}</dd>
            </div>
            <div :if={not is_nil(row[:default])}>
              <dt class="font-mono uppercase tracking-[0.14em] text-[var(--app-text-dim)]">Default</dt>
              <dd class="mt-1 font-mono">{inspect(row.default)}</dd>
            </div>
          </dl>
        </div>
      </div>
    </section>
    """
  end

  attr(:states, :list, required: true)

  defp state_projection_panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
      <div class="flex items-center justify-between gap-3">
        <p class="app-field-label">States</p>
        <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
          {length(@states)}
        </span>
      </div>

      <div :if={@states == []} class="mt-3 text-sm text-[var(--app-text-muted)]">
        No states recovered from source.
      </div>

      <div :if={@states != []} class="mt-3 space-y-3">
        <div :for={state <- @states} class="rounded-xl border border-[var(--app-border)]/70 bg-[var(--app-surface-alt)] px-3 py-3">
          <div class="flex flex-wrap items-center gap-2">
            <p class="text-sm font-semibold text-[var(--app-text)]">{state.name}</p>
            <span
              :if={state[:initial?]}
              class="rounded-full border border-emerald-400/40 bg-emerald-400/10 px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text)]"
            >
              initial
            </span>
            <span
              :if={present_text?(state[:status])}
              class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]"
            >
              {state.status}
            </span>
          </div>
          <p :if={present_text?(state[:meaning])} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            {state.meaning}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr(:transitions, :list, required: true)

  defp transition_projection_panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
      <div class="flex items-center justify-between gap-3">
        <p class="app-field-label">Transitions</p>
        <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
          {length(@transitions)}
        </span>
      </div>

      <div :if={@transitions == []} class="mt-3 text-sm text-[var(--app-text-muted)]">
        No transitions recovered from source.
      </div>

      <div :if={@transitions != []} class="mt-3 space-y-3">
        <div :for={transition <- @transitions} class="rounded-xl border border-[var(--app-border)]/70 bg-[var(--app-surface-alt)] px-3 py-3">
          <p class="font-mono text-xs text-[var(--app-text)]">
            {transition.source} -> {transition.destination}
          </p>
          <p class="mt-2 text-sm font-semibold text-[var(--app-text)]">
            {transition.family}:{transition.trigger}
          </p>
          <p :if={present_text?(transition[:meaning])} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            {transition.meaning}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr(:rows, :list, required: true)

  defp memory_projection_panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
      <div class="flex items-center justify-between gap-3">
        <p class="app-field-label">Memory Fields</p>
        <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
          {length(@rows)}
        </span>
      </div>

      <div :if={@rows == []} class="mt-3 text-sm text-[var(--app-text-muted)]">
        No memory fields declared.
      </div>

      <div :if={@rows != []} class="mt-3 space-y-3">
        <div :for={row <- @rows} class="rounded-xl border border-[var(--app-border)]/70 bg-[var(--app-surface-alt)] px-3 py-3">
          <div class="flex flex-wrap items-center gap-2">
            <p class="text-sm font-semibold text-[var(--app-text)]">{row.name}</p>
            <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
              {inspect(row.type)}
            </span>
            <span
              :if={is_boolean(row[:public?])}
              class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]"
            >
              {if row[:public?], do: "public", else: "private"}
            </span>
          </div>
          <p :if={present_text?(row[:meaning])} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            {row.meaning}
          </p>
          <p class="mt-2 font-mono text-xs text-[var(--app-text-muted)]">
            default={inspect(row.default)}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp metric_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-3">
      <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">{@label}</p>
      <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">{@value}</p>
    </div>
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

  defp assign_machine_projection(socket) do
    machine_model = socket.assigns[:machine_model]
    graph_model = socket.assigns[:machine_graph_model] || machine_model

    socket
    |> assign(:machine_diagram, MachineGraph.mermaid(graph_model))
  end

  defp graph_model_from_source(_source, model) when is_map(model), do: model

  defp graph_model_from_source(source, _model) when is_binary(source) do
    case MachineSource.graph_model_from_source(source) do
      {:ok, graph_model} -> graph_model
      {:error, _diagnostics} -> nil
    end
  end

  defp config_projection_from_source(source) when is_binary(source) do
    case MachineSource.config_projection_from_source(source) do
      {:ok, projection} -> projection
      {:error, _diagnostics} -> nil
    end
  end

  defp config_projection_from_source(_source), do: nil

  defp humanize_machine_id(nil), do: "Machine"

  defp humanize_machine_id(machine_id) when is_binary(machine_id) do
    machine_id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp compatibility_label(:fully_editable), do: "Fully editable"
  defp compatibility_label(:inspect_only), do: "Inspect only"

  defp compatibility_label(other),
    do: other |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  defp readonly_machine(socket) do
    assign(socket, :machine_issue, {:revision_read_only, StudioRevision.readonly_message()})
  end
end
