defmodule Ogol.HMIWeb.MachineStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.{Bus, CommandGateway, SnapshotStore}
  alias Ogol.HMIWeb.Components.{StudioCell, StudioLibrary}
  alias Ogol.HMIWeb.StudioRevision
  alias Ogol.Machine.Graph, as: MachineGraph
  alias Ogol.Skill
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell
  alias Ogol.Studio.MachineCell
  alias Ogol.Studio.Modules
  alias Ogol.Studio.WorkspaceStore

  @views [:config, :source, :inspect]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Bus.subscribe(Bus.overview_topic())
    end

    {:ok,
     socket
     |> assign(:page_title, "Machine Studio")
     |> assign(
       :page_summary,
       "Author canonical machine modules from a constrained visual subset or edit the source directly, then compile them into the selected runtime."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :machines)
     |> assign(:requested_view, :config)
     |> assign(:machine_issue, nil)
     |> assign(:operator_feedback, nil)
     |> assign(:operator_feedback_ref, nil)
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

  def handle_info({:machine_snapshot_updated, _snapshot}, socket) do
    {:noreply, load_machine(socket, socket.assigns[:machine_id])}
  end

  def handle_info({:operator_control_result, ref, feedback}, socket) do
    if socket.assigns.operator_feedback_ref == ref do
      {:noreply,
       socket
       |> assign(:operator_feedback_ref, nil)
       |> assign(:operator_feedback, feedback)
       |> load_machine(socket.assigns[:machine_id])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_view", %{"view" => view}, socket) do
    view =
      view
      |> String.to_existing_atom()
      |> then(fn view -> if view in @views, do: view, else: :config end)

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
           |> assign(:machine_graph_model, model)
           |> assign(:machine_projection, config_projection_from_source(source))
           |> assign(:visual_form, MachineSource.form_from_model(model))
           |> assign(:draft_source, source)
           |> assign(:current_source_digest, Build.digest(source))
           |> assign(:sync_state, :synced)
           |> assign(:sync_diagnostics, [])
           |> assign(:validation_errors, [])
           |> assign(:machine_issue, nil)
           |> assign(:runtime_status, current_runtime_status(socket.assigns.machine_id))
           |> assign_runtime_projection()}

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
       |> assign(:machine_graph_model, graph_model_from_source(source, model))
       |> assign(:machine_projection, config_projection_from_source(source))
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
       |> assign(:runtime_status, current_runtime_status(socket.assigns.machine_id))
       |> assign_runtime_projection()}
    end
  end

  def handle_event("request_transition", %{"transition" => "compile"}, socket) do
    case WorkspaceStore.compile_machine(socket.assigns.machine_id) do
      {:ok, draft} ->
        {:noreply,
         socket
         |> assign(:machine_draft, draft)
         |> assign(:runtime_status, current_runtime_status(socket.assigns.machine_id))
         |> assign(:machine_issue, nil)
         |> assign_runtime_projection()}

      {:error, diagnostics, draft} when is_list(diagnostics) ->
        {:noreply,
         socket
         |> assign(:machine_draft, draft)
         |> assign(:runtime_status, current_runtime_status(socket.assigns.machine_id))
         |> assign(:machine_issue, nil)
         |> assign_runtime_projection()}

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

  def handle_event("select_runtime_target", %{"runtime_target" => target}, socket) do
    {:noreply, assign_runtime_projection(socket, selected_runtime_target: blank_to_nil(target))}
  end

  def handle_event(
        "invoke_skill",
        %{"machine_id" => machine_id, "skill" => skill_name} = params,
        socket
      ) do
    payload_source = Map.get(params, "payload", "")

    with {:ok, runtime_target} <-
           resolve_runtime_target(socket.assigns.runtime_instances, machine_id),
         {:ok, skill} <- resolve_skill(socket.assigns.machine_skills, skill_name),
         {:ok, payload} <- decode_skill_payload(payload_source) do
      ref = make_ref()
      dispatch_control_async(self(), ref, runtime_target.machine_id, skill.name, payload)

      {:noreply,
       socket
       |> assign(:operator_feedback_ref, ref)
       |> assign(
         :operator_feedback,
         operator_feedback(:pending, runtime_target.machine_id, skill.name, :dispatching)
       )}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:operator_feedback_ref, nil)
         |> assign(:operator_feedback, operator_feedback(:error, machine_id, skill_name, reason))}
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
          <.machine_config_screen
            :if={@machine_cell.selected_view == :config}
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

          <.source_editor
            :if={@machine_cell.selected_view == :source}
            draft_source={@draft_source}
            read_only?={@studio_read_only?}
          />

          <.machine_inspect_screen
            :if={@machine_cell.selected_view == :inspect}
            machine_id={@machine_id}
            machine_model={@machine_graph_model}
            machine_diagram={@machine_runtime_diagram}
            compiled_current?={@compiled_current?}
            runtime_instances={@runtime_instances}
            selected_runtime_target={@selected_runtime_target}
            selected_runtime={@selected_runtime}
            machine_skills={@machine_skills}
            operator_feedback={@operator_feedback}
          />
        </:body>
      </StudioCell.cell>

      <section :if={!@machine_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Machines</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          The current workspace does not contain any machines
        </h2>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          Load a revision that includes machines, or create a new machine in Draft mode.
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
      |> assign(:machine_graph_model, graph_model_from_source(draft.source, model))
      |> assign(:machine_projection, config_projection_from_source(draft.source))
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
      |> assign_runtime_projection()
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
        MachineSource.form_from_model(MachineSource.default_model("machine"))
      )
      |> assign(:draft_source, "")
      |> assign(:current_source_digest, Build.digest(""))
      |> assign(:sync_state, :synced)
      |> assign(:sync_diagnostics, [])
      |> assign(:validation_errors, [])
      |> assign(:machine_issue, nil)
      |> assign(:runtime_status, MachineCell.default_runtime_status())
      |> assign_runtime_projection()
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
        <.machine_graph_panel
          machine_id={@machine_id}
          machine_model={@machine_projection || @machine_model}
          machine_diagram={@machine_diagram}
          selected_runtime={nil}
          title="Canonical machine flow"
          summary="Mermaid is generated from the current machine source. Config shows the richest projection we can recover without requiring a live runtime."
        />

        <.machine_structure_panel :if={@machine_projection} machine={@machine_projection} />
      </aside>
    </div>
    """
  end

  attr(:machine_id, :string, default: nil)
  attr(:machine_model, :map, default: nil)
  attr(:machine_diagram, :string, default: nil)
  attr(:compiled_current?, :boolean, required: true)
  attr(:runtime_instances, :list, required: true)
  attr(:selected_runtime_target, :string, default: nil)
  attr(:selected_runtime, :any, default: nil)
  attr(:machine_skills, :list, required: true)
  attr(:operator_feedback, :map, default: nil)

  defp machine_inspect_screen(assigns) do
    ~H"""
    <div class="grid gap-5 2xl:grid-cols-[minmax(0,1fr)_minmax(22rem,0.9fr)]">
      <div class="min-w-0">
        <.machine_graph_panel
          machine_id={@machine_id}
          machine_model={@machine_model}
          machine_diagram={@machine_diagram}
          selected_runtime={@selected_runtime}
          title="Live state graph"
          summary="The selected live runtime instance drives the highlighted state. Compile the current source first if you want runtime inspection to match this machine."
        />
      </div>

      <aside class="space-y-4">
        <.machine_runtime_panel
          compiled_current?={@compiled_current?}
          runtime_instances={@runtime_instances}
          selected_runtime_target={@selected_runtime_target}
          selected_runtime={@selected_runtime}
          machine_skills={@machine_skills}
          operator_feedback={@operator_feedback}
        />
      </aside>
    </div>
    """
  end

  attr(:machine_id, :string, default: nil)
  attr(:machine_model, :map, default: nil)
  attr(:machine_diagram, :string, default: nil)
  attr(:selected_runtime, :any, default: nil)
  attr(:title, :string, required: true)
  attr(:summary, :string, required: true)

  defp machine_graph_panel(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <p class="app-kicker">State Graph</p>
      <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
        {@title}
      </h3>
      <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
        {@summary}
      </p>

      <div :if={@machine_diagram} class="mt-4 rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] p-3">
        <div
          id={"machine-mermaid-#{@machine_id || "draft"}"}
          phx-hook="MermaidDiagram"
          data-diagram={@machine_diagram}
          class="machine-mermaid min-h-[16rem]"
        >
        </div>
      </div>

      <div :if={is_nil(@machine_diagram)} class="mt-4 rounded-xl border border-dashed border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-6 text-sm text-[var(--app-text-muted)]">
        Parse the machine into the supported model to render the graph here.
      </div>

      <div :if={@machine_model} class="mt-4 grid gap-3 sm:grid-cols-3">
        <.metric_card
          label="States"
          value={Integer.to_string(length(Map.get(@machine_model, :states, [])))}
        />
        <.metric_card
          label="Transitions"
          value={Integer.to_string(length(Map.get(@machine_model, :transitions, [])))}
        />
        <.metric_card
          label="Live State"
          value={runtime_state_label(@selected_runtime)}
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

  attr(:compiled_current?, :boolean, required: true)
  attr(:runtime_instances, :list, required: true)
  attr(:selected_runtime_target, :string, default: nil)
  attr(:selected_runtime, :map, default: nil)
  attr(:machine_skills, :list, required: true)
  attr(:operator_feedback, :map, default: nil)

  defp machine_runtime_panel(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <p class="app-kicker">Runtime</p>
      <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
        Public skills and live instances
      </h3>
      <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
        Runtime invocation is limited to the selected live instance of the currently compiled machine module.
      </p>

      <form phx-change="select_runtime_target" class="mt-4 space-y-2">
        <label class="space-y-2">
          <span class="app-field-label">Live Instance</span>
          <select name="runtime_target" class="app-input w-full">
            <option value="">
              {if @runtime_instances == [], do: "No live instances", else: "Select a runtime instance"}
            </option>
            <option
              :for={runtime <- @runtime_instances}
              value={runtime_target_value(runtime)}
              selected={runtime_target_value(runtime) == @selected_runtime_target}
            >
              {runtime_target_label(runtime)}
            </option>
          </select>
        </label>
      </form>

      <div class="mt-4 grid gap-3 sm:grid-cols-2">
        <.metric_card label="Compiled Current" value={yes_no(@compiled_current?)} />
        <.metric_card label="Selected State" value={runtime_state_label(@selected_runtime)} />
      </div>

      <div
        :if={@operator_feedback}
        class={[
          "mt-4 rounded-xl border px-3 py-3",
          operator_feedback_classes(@operator_feedback.status)
        ]}
      >
        <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
          Runtime Call
        </p>
        <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">
          {operator_feedback_summary(@operator_feedback)}
        </p>
        <p class="mt-2 font-mono text-[11px] text-[var(--app-text-muted)]">
          {operator_feedback_detail(@operator_feedback)}
        </p>
      </div>

      <div :if={@machine_skills == []} class="mt-4 rounded-xl border border-dashed border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-6 text-sm text-[var(--app-text-muted)]">
        No public skills are available for the current machine surface.
      </div>

      <div :if={@machine_skills != []} class="mt-4 space-y-3">
        <form
          :for={skill <- @machine_skills}
          phx-submit="invoke_skill"
          class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4"
        >
          <input type="hidden" name="machine_id" value={@selected_runtime_target || ""} />
          <input type="hidden" name="skill" value={to_string(skill.name)} />

          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <p class="text-sm font-semibold text-[var(--app-text)]">{skill.name}</p>
                <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.2em] text-[var(--app-text-dim)]">
                  {skill.kind}
                </span>
              </div>
              <p :if={skill.summary} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                {skill.summary}
              </p>
            </div>

            <button
              type="submit"
              class="app-button shrink-0 disabled:cursor-not-allowed disabled:opacity-60"
              disabled={not skill_invokable?(@compiled_current?, @selected_runtime)}
              title={skill_disabled_reason(@compiled_current?, @selected_runtime)}
            >
              Invoke
            </button>
          </div>

          <label class="mt-4 block space-y-2">
            <span class="app-field-label">JSON Payload</span>
            <textarea
              name="payload"
              rows="4"
              class="app-textarea w-full font-mono text-[12px] leading-6"
            >{default_skill_payload(skill)}</textarea>
          </label>
        </form>
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

  defp assign_runtime_projection(socket, overrides \\ []) do
    machine_model = socket.assigns[:machine_model]
    graph_model = socket.assigns[:machine_graph_model] || machine_model
    machine_projection = socket.assigns[:machine_projection] || machine_model
    runtime_status = socket.assigns[:runtime_status] || MachineCell.default_runtime_status()
    current_source_digest = socket.assigns[:current_source_digest]
    compiled_current? = compiled_current?(runtime_status, current_source_digest)

    runtime_instances = runtime_instances_for(graph_model)

    selected_runtime_target =
      resolve_selected_runtime_target(
        Keyword.get(
          overrides,
          :selected_runtime_target,
          socket.assigns[:selected_runtime_target]
        ),
        runtime_instances
      )

    selected_runtime = runtime_instance_by_target(runtime_instances, selected_runtime_target)

    socket
    |> assign(:compiled_current?, compiled_current?)
    |> assign(:machine_diagram, MachineGraph.mermaid(graph_model))
    |> assign(
      :machine_runtime_diagram,
      MachineGraph.mermaid(
        graph_model,
        active_state: selected_runtime && selected_runtime.current_state
      )
    )
    |> assign(:runtime_instances, runtime_instances)
    |> assign(:selected_runtime_target, selected_runtime_target)
    |> assign(:selected_runtime, selected_runtime)
    |> assign(
      :machine_skills,
      machine_skills(machine_projection, runtime_status, compiled_current?)
    )
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

  defp runtime_instances_for(nil), do: []

  defp runtime_instances_for(%{module_name: module_name}) when is_binary(module_name) do
    module = MachineSource.module_from_name!(module_name)

    SnapshotStore.list_machines()
    |> Enum.filter(&(&1.module == module))
    |> Enum.sort_by(&to_string(&1.machine_id))
  rescue
    ArgumentError -> []
  end

  defp runtime_instances_for(_model), do: []

  defp resolve_selected_runtime_target(nil, runtime_instances) do
    runtime_instances
    |> List.first()
    |> runtime_target_value()
  end

  defp resolve_selected_runtime_target(target, runtime_instances) when is_binary(target) do
    if Enum.any?(runtime_instances, &(runtime_target_value(&1) == target)) do
      target
    else
      resolve_selected_runtime_target(nil, runtime_instances)
    end
  end

  defp resolve_selected_runtime_target(_target, runtime_instances),
    do: resolve_selected_runtime_target(nil, runtime_instances)

  defp runtime_instance_by_target(runtime_instances, target) when is_binary(target) do
    Enum.find(runtime_instances, &(runtime_target_value(&1) == target))
  end

  defp runtime_instance_by_target(_runtime_instances, _target), do: nil

  defp machine_skills(machine_model, runtime_status, true) do
    case Map.get(runtime_status, :module) do
      module when is_atom(module) ->
        if function_exported?(module, :skills, 0) do
          module.skills()
        else
          preview_skills(machine_model)
        end

      _other ->
        preview_skills(machine_model)
    end
  end

  defp machine_skills(machine_model, _runtime_status, _compiled_current?),
    do: preview_skills(machine_model)

  defp preview_skills(nil), do: []

  defp preview_skills(machine_model) do
    request_skills =
      machine_model
      |> Map.get(:requests, [])
      |> Enum.map(&preview_skill(&1, :request))

    event_skills =
      machine_model
      |> Map.get(:events, [])
      |> Enum.map(&preview_skill(&1, :event))

    Enum.sort_by(request_skills ++ event_skills, &{&1.kind, to_string(&1.name)})
  end

  defp preview_skill(row, kind) do
    %Skill{
      name: to_string(row.name),
      kind: kind,
      summary: Map.get(row, :meaning)
    }
  end

  defp compiled_current?(%{module: module, source_digest: source_digest}, current_source_digest)
       when is_atom(module) and is_binary(source_digest) and is_binary(current_source_digest),
       do: source_digest == current_source_digest

  defp compiled_current?(_runtime_status, _current_source_digest), do: false

  defp runtime_target_value(nil), do: nil
  defp runtime_target_value(%{machine_id: machine_id}), do: to_string(machine_id)

  defp runtime_target_label(runtime) do
    [
      to_string(runtime.machine_id),
      runtime.current_state && "state=#{runtime.current_state}",
      runtime.health && "health=#{runtime.health}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" | ")
  end

  defp runtime_state_label(nil), do: "No live instance"
  defp runtime_state_label(%{current_state: nil}), do: "Unknown"
  defp runtime_state_label(%{current_state: current_state}), do: to_string(current_state)

  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"

  defp skill_invokable?(true, runtime) when is_map(runtime), do: true
  defp skill_invokable?(_compiled_current?, _runtime), do: false

  defp skill_disabled_reason(false, _runtime),
    do: "Compile the current source first so the runtime matches this machine."

  defp skill_disabled_reason(_compiled_current?, nil),
    do: "Select a live runtime instance for this machine module."

  defp skill_disabled_reason(_compiled_current?, _runtime), do: nil

  defp default_skill_payload(%Skill{}), do: "{}"

  defp resolve_runtime_target(runtime_instances, machine_id) when is_binary(machine_id) do
    case Enum.find(runtime_instances, &(runtime_target_value(&1) == machine_id)) do
      nil -> {:error, {:machine_unavailable, machine_id}}
      runtime -> {:ok, runtime}
    end
  end

  defp resolve_skill(skills, name) when is_binary(name) do
    case Enum.find(skills, &(to_string(&1.name) == name)) do
      nil -> {:error, {:unknown_skill, name}}
      %Skill{} = skill -> {:ok, skill}
    end
  end

  defp decode_skill_payload(""), do: {:ok, %{}}

  defp decode_skill_payload(payload) when is_binary(payload) do
    with {:ok, decoded} <- Jason.decode(payload),
         true <- is_map(decoded) do
      {:ok, decoded}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, {:invalid_payload, Exception.message(error)}}

      false ->
        {:error, {:invalid_payload, "payload must be a JSON object"}}
    end
  end

  defp dispatch_control_async(owner, ref, machine_id, skill_name, payload) do
    Task.start(fn ->
      feedback =
        case CommandGateway.invoke(machine_id, skill_name, payload) do
          {:ok, reply} -> operator_feedback(:ok, machine_id, skill_name, reply)
          {:error, reason} -> operator_feedback(:error, machine_id, skill_name, reason)
        end

      send(owner, {:operator_control_result, ref, feedback})
    end)
  end

  defp operator_feedback(status, machine_id, name, detail) do
    %{status: status, machine_id: machine_id, name: name, detail: detail}
  end

  defp operator_feedback_summary(feedback) do
    machine = feedback.machine_id |> to_string()
    name = feedback.name |> to_string()
    "#{machine} :: skill #{name}"
  end

  defp operator_feedback_detail(%{status: :pending}), do: "invoking skill"
  defp operator_feedback_detail(%{status: :ok, detail: detail}), do: "reply=#{inspect(detail)}"

  defp operator_feedback_detail(%{status: :error, detail: detail}),
    do: "reason=#{inspect(detail)}"

  defp operator_feedback_classes(:ok), do: "border-emerald-400/30 bg-emerald-400/10"
  defp operator_feedback_classes(:pending), do: "border-cyan-400/30 bg-cyan-400/10"
  defp operator_feedback_classes(:error), do: "border-rose-400/30 bg-rose-400/10"

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

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp readonly_machine(socket) do
    assign(socket, :machine_issue, {:revision_read_only, StudioRevision.readonly_message()})
  end
end
