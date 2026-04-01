defmodule OgolWeb.Studio.SequenceLive do
  use OgolWeb, :live_view

  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Studio.Library, as: StudioLibrary
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias OgolWeb.Live.SessionAction, as: SessionAction
  alias OgolWeb.Live.SessionSync
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell, as: StudioCellModel
  alias Ogol.Sequence.Studio.Cell, as: SequenceCell
  alias Ogol.Session
  alias Ogol.Topology.Source, as: TopologySource

  @views [:visual, :source]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sequence Studio")
     |> assign(
       :page_summary,
       "Author source-first orchestration sequences over machine contracts. Visual stays an honest summary of the parsed and compiled canonical sequence model."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :sequences)
     |> assign(:requested_view, :visual)
     |> assign(:sequence_issue, nil)
     |> assign(:contract_context, empty_contract_context())
     |> assign(:runtime_status, SequenceCell.default_runtime_status())
     |> assign(:step_builder, empty_step_builder())
     |> StudioRevision.subscribe()
     |> load_sequence(nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket =
      socket
      |> StudioRevision.apply_param(params)
      |> SessionSync.ensure_entry(:sequence, params["sequence_id"])

    {:noreply, load_sequence(socket, params["sequence_id"])}
  end

  @impl true
  def handle_info({:operations, operations}, socket) do
    {:noreply,
     socket
     |> StudioRevision.apply_operations(operations)
     |> load_sequence(socket.assigns[:sequence_id])}
  end

  def handle_info({:workspace_updated, _operation, _reply, _session}, socket) do
    {:noreply,
     socket
     |> StudioRevision.sync_session()
     |> load_sequence(socket.assigns[:sequence_id])}
  end

  @impl true
  def handle_event("select_view", %{"view" => view}, socket) do
    view =
      view
      |> String.to_existing_atom()
      |> then(fn selected -> if selected in @views, do: selected, else: :source end)

    {:noreply, assign(socket, :requested_view, view)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("new_sequence", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_sequence(socket)}
    else
      draft = Session.create_sequence()
      {:noreply, push_patch(socket, to: ~p"/studio/sequences/#{draft.id}")}
    end
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_sequence(socket)}
    else
      {model, sync_state, diagnostics} =
        case SequenceSource.from_source(source) do
          {:ok, model} -> {model, :synced, []}
          {:error, diagnostics} -> {nil, :unsupported, diagnostics}
        end

      draft =
        Session.save_sequence_source(
          socket.assigns.sequence_id,
          source,
          model,
          sync_state,
          diagnostics
        )

      {:noreply,
       socket
       |> assign(:sequence_draft, draft)
       |> assign(:sequence_model, model)
       |> assign(:contract_context, contract_context(socket.assigns, model))
       |> assign(:draft_source, source)
       |> assign(:current_source_digest, Build.digest(source))
       |> assign(:sync_state, sync_state)
       |> assign(:sync_diagnostics, diagnostics)
       |> assign(:runtime_status, current_runtime_status(socket.assigns.sequence_id))
       |> assign(:compiled_model, current_compiled_model(socket.assigns.sequence_id, source))
       |> assign(
         :step_builder,
         step_builder_for(socket.assigns, model, socket.assigns.step_builder)
       )
       |> assign(:sequence_issue, nil)}
    end
  end

  def handle_event("change_step_builder", %{"builder" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :step_builder,
       normalize_step_builder(
         params,
         socket.assigns.contract_context,
         socket.assigns.sequence_model
       )
     )}
  end

  def handle_event("add_sequence_procedure", %{"procedure" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_sequence(socket)}
    else
      case add_procedure_to_model(socket.assigns.sequence_model, params) do
        {:ok, model} ->
          {:noreply, persist_visual_model(socket, model)}

        {:error, message} ->
          {:noreply, assign(socket, :sequence_issue, {:visual_edit_failed, message})}
      end
    end
  end

  def handle_event("add_sequence_step", %{"builder" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_sequence(socket)}
    else
      builder =
        normalize_step_builder(
          params,
          socket.assigns.contract_context,
          socket.assigns.sequence_model
        )

      case add_step_to_model(socket.assigns.sequence_model, builder) do
        {:ok, model} ->
          {:noreply, persist_visual_model(socket, model, builder)}

        {:error, message} ->
          {:noreply,
           socket
           |> assign(:step_builder, builder)
           |> assign(:sequence_issue, {:visual_edit_failed, message})}
      end
    end
  end

  def handle_event(
        "remove_sequence_step",
        %{"scope" => scope, "index" => index} = params,
        socket
      ) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_sequence(socket)}
    else
      case remove_step_from_model(
             socket.assigns.sequence_model,
             scope,
             Map.get(params, "procedure"),
             index
           ) do
        {:ok, model} ->
          {:noreply, persist_visual_model(socket, model)}

        {:error, message} ->
          {:noreply, assign(socket, :sequence_issue, {:visual_edit_failed, message})}
      end
    end
  end

  def handle_event("remove_sequence_procedure", %{"procedure" => procedure}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_sequence(socket)}
    else
      case remove_procedure_from_model(socket.assigns.sequence_model, procedure) do
        {:ok, model} ->
          {:noreply, persist_visual_model(socket, model)}

        {:error, message} ->
          {:noreply, assign(socket, :sequence_issue, {:visual_edit_failed, message})}
      end
    end
  end

  def handle_event("request_transition", %{"transition" => "compile"}, socket) do
    case current_sequence_action(socket.assigns, "compile") do
      nil ->
        {:noreply, socket}

      action ->
        SessionAction.reduce_action(
          socket,
          action,
          guard: fn socket ->
            if StudioRevision.read_only?(socket) do
              {:error, readonly_sequence(socket)}
            else
              :ok
            end
          end,
          after: fn socket, reply ->
            case reply do
              {:ok, _status} ->
                runtime_status = current_runtime_status(socket.assigns.sequence_id)

                socket
                |> assign(:runtime_status, runtime_status)
                |> assign(
                  :compiled_model,
                  current_compiled_model(socket.assigns.sequence_id, socket.assigns.draft_source)
                )
                |> assign(:sequence_issue, nil)

              {:error, %{} = _status} ->
                socket
                |> assign(:runtime_status, current_runtime_status(socket.assigns.sequence_id))
                |> assign(:compiled_model, nil)
                |> assign(:sequence_issue, nil)

              {:error, :module_not_found} ->
                socket
                |> assign(:runtime_status, current_runtime_status(socket.assigns.sequence_id))
                |> assign(:compiled_model, nil)
                |> assign(
                  :sequence_issue,
                  {:compile_missing_module,
                   "Source must define one sequence module before it can be compiled."}
                )
            end
          end
        )
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:sequence_cell, current_sequence_cell(assigns))
      |> assign(
        :sequence_items,
        sequence_items(
          assigns.sequence_library,
          assigns.sequence_id,
          assigns.studio_selected_revision
        )
      )

    ~H"""
    <section class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
      <StudioLibrary.list
        title="Sequences"
        items={@sequence_items}
        current_id={@sequence_id}
        empty_label="No sequences in the current workspace."
      >
        <:actions>
          <button
            type="button"
            phx-click="new_sequence"
            class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
            disabled={@studio_read_only?}
            title={if(@studio_read_only?, do: StudioRevision.readonly_message())}
          >
            New
          </button>
        </:actions>
      </StudioLibrary.list>

      <StudioCell.cell :if={@sequence_draft} body_class="min-h-[56rem]">
        <:actions>
          <StudioCell.action_button
            :for={action <- @sequence_cell.actions}
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
            :for={view <- @sequence_cell.views}
            type="button"
            phx-click="select_view"
            phx-value-view={view.id}
            selected={@sequence_cell.selected_view == view.id}
            available={view.available?}
            data-test={"sequence-view-#{view.id}"}
          >
            {view.label}
          </StudioCell.view_button>
        </:views>

        <:notice :if={@sequence_cell.notice}>
          <StudioCell.notice
            tone={@sequence_cell.notice.tone}
            title={@sequence_cell.notice.title}
            message={@sequence_cell.notice.message}
          />
        </:notice>

        <:body>
          <.visual_summary
            :if={@sequence_cell.selected_view == :visual}
            sequence_model={@sequence_model}
            compiled_model={@compiled_model}
            contract_context={@contract_context}
            step_builder={@step_builder}
            read_only?={@studio_read_only?}
          />

          <.source_editor
            :if={@sequence_cell.selected_view == :source}
            draft_source={@draft_source}
            read_only?={@studio_read_only?}
          />
        </:body>
      </StudioCell.cell>

      <section :if={!@sequence_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Sequences</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          The current workspace does not contain any sequences
        </h2>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          Load a revision that includes sequences, or create a new sequence in Draft mode.
        </p>
      </section>
    </section>
    """
  end

  defp load_sequence(socket, sequence_id) do
    {resolved_sequence_id, draft, library} = sequence_snapshot(socket, sequence_id)

    if draft do
      model =
        draft.model ||
          case SequenceSource.from_source(draft.source) do
            {:ok, model} -> model
            {:error, _diagnostics} -> nil
          end

      socket
      |> assign(:sequence_id, resolved_sequence_id)
      |> assign(:sequence_draft, draft)
      |> assign(:sequence_library, library)
      |> assign(:sequence_model, model)
      |> assign(:contract_context, contract_context(socket.assigns, model))
      |> assign(:draft_source, draft.source)
      |> assign(:current_source_digest, Build.digest(draft.source))
      |> assign(:sync_state, draft.sync_state)
      |> assign(:sync_diagnostics, draft.sync_diagnostics)
      |> assign(:runtime_status, current_runtime_status(resolved_sequence_id))
      |> assign(:compiled_model, current_compiled_model(resolved_sequence_id, draft.source))
      |> assign(:step_builder, step_builder_for(socket.assigns, model))
      |> assign(:sequence_issue, nil)
    else
      socket
      |> assign(:sequence_id, nil)
      |> assign(:sequence_draft, nil)
      |> assign(:sequence_library, library)
      |> assign(:sequence_model, nil)
      |> assign(:contract_context, empty_contract_context())
      |> assign(:draft_source, "")
      |> assign(:current_source_digest, Build.digest(""))
      |> assign(:sync_state, :synced)
      |> assign(:sync_diagnostics, [])
      |> assign(:runtime_status, SequenceCell.default_runtime_status())
      |> assign(:compiled_model, nil)
      |> assign(:step_builder, empty_step_builder())
      |> assign(:sequence_issue, nil)
    end
  end

  defp sequence_snapshot(socket, requested_id) do
    drafts = SessionSync.list_entries(socket, :sequence)
    draft = select_sequence_draft(drafts, requested_id)
    {draft && draft.id, draft, drafts}
  end

  defp select_sequence_draft(drafts, requested_id) do
    Enum.find(drafts, &(&1.id == requested_id)) || List.first(drafts)
  end

  defp sequence_items(drafts, current_id, selected_revision) do
    Enum.map(drafts, fn draft ->
      %{
        id: draft.id,
        label: sequence_label(draft),
        detail: sequence_detail(draft),
        path:
          StudioRevision.path_with_revision(~p"/studio/sequences/#{draft.id}", selected_revision),
        status: sequence_status(draft, current_id)
      }
    end)
  end

  defp sequence_label(%{model: %{meaning: meaning}}) when is_binary(meaning) and meaning != "",
    do: meaning

  defp sequence_label(draft) do
    draft.id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp sequence_detail(%{model: model}) when is_map(model), do: SequenceSource.summary(model)
  defp sequence_detail(_draft), do: "Source-only draft"

  defp sequence_status(%{id: id}, current_id) when id == current_id, do: "Open"

  defp sequence_status(%{source: source, id: id}, _current_id) do
    runtime_status = current_runtime_status(id)

    case StudioCellModel.source_lifecycle(
           Build.digest(source),
           runtime_status.source_digest,
           runtime_status.diagnostics
         ) do
      :compiled -> "Compiled"
      :compile_error -> "Compile Error"
      _other -> "Synced"
    end
  end

  defp sequence_status(%{sync_state: :synced}, _current_id), do: "Synced"
  defp sequence_status(%{sync_state: :unsupported}, _current_id), do: "Source-only"

  defp readonly_sequence(socket) do
    assign(
      socket,
      :sequence_issue,
      {:revision_read_only, StudioRevision.readonly_message()}
    )
  end

  attr(:sequence_model, :map, default: nil)
  attr(:compiled_model, :any, default: nil)
  attr(:contract_context, :map, default: %{topology: nil, machines: [], diagnostics: []})
  attr(:step_builder, :map, default: %{})
  attr(:read_only?, :boolean, default: false)

  defp visual_summary(assigns) do
    ~H"""
    <div :if={@sequence_model} class="grid gap-5">
      <section class="grid gap-4 xl:grid-cols-3">
        <.summary_card title="Module" value={@sequence_model.module_name} />
        <.summary_card title="Sequence Name" value={":" <> to_string(@sequence_model.name)} />
        <.summary_card title="Topology" value={@sequence_model.topology_module_name} />
      </section>

      <.contract_browser contract_context={@contract_context} />

      <.visual_builder
        contract_context={@contract_context}
        sequence_model={@sequence_model}
        step_builder={@step_builder}
        read_only?={@read_only?}
      />

      <section class="grid gap-4 xl:grid-cols-[0.9fr_1.1fr]">
        <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
          <p class="app-kicker">Invariants</p>
          <div class="mt-3 space-y-3">
            <p
              :if={@sequence_model.invariants == []}
              class="text-sm leading-6 text-[var(--app-text-muted)]"
            >
              No invariants declared yet.
            </p>

            <div
              :for={invariant <- @sequence_model.invariants}
              class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-3"
            >
              <p class="font-mono text-[12px] leading-6 text-[var(--app-text)]">
                {invariant.condition}
              </p>
              <p :if={invariant.meaning} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                {invariant.meaning}
              </p>
            </div>
          </div>
        </section>

        <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
          <p class="app-kicker">Root Flow</p>
          <.editable_step_list
            steps={@sequence_model.root_steps}
            scope="root"
            read_only?={@read_only?}
            empty_label="Root flow is empty."
          />
        </section>
      </section>

      <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
        <p class="app-kicker">Procedures</p>
        <div class="mt-3 grid gap-4 xl:grid-cols-2">
          <section
            :for={procedure <- @sequence_model.procedures}
            class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="text-sm font-semibold text-[var(--app-text)]">
                  {":" <> procedure.name}
                </p>
                <p :if={procedure.meaning} class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">
                  {procedure.meaning}
                </p>
              </div>
              <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
                {length(procedure.steps)} steps
              </span>
            </div>
            <div class="mt-3 flex justify-end">
              <button
                type="button"
                phx-click="remove_sequence_procedure"
                phx-value-procedure={procedure.name}
                class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
                disabled={@read_only?}
              >
                Remove Procedure
              </button>
            </div>
            <div class="mt-3 space-y-3">
              <.editable_step_list
                steps={procedure.steps}
                scope="procedure"
                procedure={procedure.name}
                read_only?={@read_only?}
                empty_label="This procedure has no steps yet."
              />
            </div>
          </section>
        </div>
      </section>

      <section
        :if={@compiled_model}
        class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
      >
        <p class="app-kicker">Compiled Canonical Model</p>
        <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
          Compile resolved the sequence against the referenced topology and public machine contracts.
        </p>
        <div class="mt-3 grid gap-4 xl:grid-cols-3">
          <.summary_card
            title="Root Steps"
            value={Integer.to_string(length(@compiled_model.sequence.root))}
          />
          <.summary_card
            title="Procedures"
            value={Integer.to_string(length(@compiled_model.sequence.procedures))}
          />
          <.summary_card
            title="Module"
            value={inspect(@compiled_model.module)}
          />
        </div>
      </section>
    </div>

    <section
      :if={!@sequence_model}
      class="rounded-2xl border border-dashed border-[var(--app-border)] px-5 py-5"
    >
      <p class="app-kicker">Visual Summary</p>
      <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
        Source-only sequence draft
      </h2>
      <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
        The current source could not be recovered into the managed visual sequence subset. Continue editing in Source mode.
      </p>
    </section>
    """
  end

  attr(:contract_context, :map, required: true)

  defp contract_browser(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p class="app-kicker">Available Machines</p>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
            Sequences can only orchestrate the selected topology's built public machine contracts: skills, durable status, and public signals.
          </p>
        </div>
        <span
          :if={@contract_context.topology}
          class="rounded-full border border-[var(--app-border)] px-2 py-0.5 text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]"
        >
          {length(@contract_context.machines)} machines
        </span>
      </div>

      <div :if={@contract_context.diagnostics != []} class="mt-4 space-y-2">
        <p
          :for={message <- @contract_context.diagnostics}
          class="rounded-xl border border-[var(--app-danger)]/40 bg-[var(--app-danger)]/10 px-3 py-2 text-sm leading-6 text-[var(--app-danger)]"
        >
          {message}
        </p>
      </div>

      <p
        :if={!@contract_context.topology and @contract_context.diagnostics == []}
        class="mt-4 text-sm leading-6 text-[var(--app-text-muted)]"
      >
        No topology contract is available for this sequence yet.
      </p>

      <div :if={@contract_context.topology} class="mt-4 space-y-4">
        <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p class="text-sm font-semibold text-[var(--app-text)]">
                {@contract_context.topology.topology_id}
              </p>
              <p class="mt-1 font-mono text-[12px] leading-6 text-[var(--app-text-muted)]">
                {@contract_context.topology.module_name}
              </p>
            </div>
            <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
              topology
            </span>
          </div>
          <p
            :if={@contract_context.topology.meaning}
            class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]"
          >
            {@contract_context.topology.meaning}
          </p>
        </section>

        <div class="grid gap-4 xl:grid-cols-2">
          <section
            :for={machine <- @contract_context.machines}
            class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4"
          >
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p class="text-sm font-semibold text-[var(--app-text)]">
                  {machine.name}
                </p>
                <p class="mt-1 font-mono text-[12px] leading-6 text-[var(--app-text-muted)]">
                  {machine.module_name}
                </p>
              </div>
            </div>

            <p :if={machine.meaning} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
              {machine.meaning}
            </p>

            <div :if={machine.diagnostics != []} class="mt-3 space-y-2">
              <p
                :for={message <- machine.diagnostics}
                class="rounded-xl border border-[var(--app-danger)]/30 bg-[var(--app-danger)]/10 px-3 py-2 text-sm leading-6 text-[var(--app-danger)]"
              >
                {message}
              </p>
            </div>

            <div class="mt-4 grid gap-3 xl:grid-cols-3">
              <.contract_group
                title="Skills"
                empty_label="No public skills."
                items={machine.skills}
              />
              <.contract_group
                title="Status"
                empty_label="No public status."
                items={machine.status}
              />
              <.contract_group
                title="Signals"
                empty_label="No public signals."
                items={machine.signals}
              />
            </div>
          </section>
        </div>
      </div>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:empty_label, :string, required: true)
  attr(:items, :list, default: [])

  defp contract_group(assigns) do
    ~H"""
    <section class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-3">
      <p class="app-kicker">{@title}</p>
      <div class="mt-3 space-y-2">
        <p :if={@items == []} class="text-sm leading-6 text-[var(--app-text-muted)]">
          {@empty_label}
        </p>

        <div
          :for={item <- @items}
          class="rounded-lg border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-2"
        >
          <div class="flex flex-wrap items-start justify-between gap-2">
            <p class="font-mono text-[12px] leading-6 text-[var(--app-text)]">
              {item.name}
            </p>
            <span
              :if={item[:kind]}
              class="rounded-full border border-[var(--app-border)] px-2 py-0.5 text-[10px] uppercase tracking-[0.16em] text-[var(--app-text-dim)]"
            >
              {item.kind}
            </span>
          </div>
          <p :if={item[:summary]} class="mt-1 text-sm leading-6 text-[var(--app-text-muted)]">
            {item.summary}
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr(:contract_context, :map, required: true)
  attr(:sequence_model, :map, required: true)
  attr(:step_builder, :map, required: true)
  attr(:read_only?, :boolean, default: false)

  defp visual_builder(assigns) do
    machine_options = builder_machine_options(assigns.contract_context)
    procedure_options = builder_procedure_options(assigns.sequence_model)
    skill_options = builder_skill_options(assigns.contract_context, assigns.step_builder)
    status_options = builder_status_options(assigns.contract_context, assigns.step_builder)
    target_is_procedure? = Map.get(assigns.step_builder, "target") == "procedure"
    step_kind = Map.get(assigns.step_builder, "kind")
    show_machine_fields? = step_kind in ["do_skill", "wait_status"]
    show_timeout_fields? = step_kind == "wait_status"
    show_run_fields? = step_kind == "run"
    show_fail_fields? = step_kind == "fail"

    assigns =
      assigns
      |> assign(:machine_options, machine_options)
      |> assign(:procedure_options, procedure_options)
      |> assign(:skill_options, skill_options)
      |> assign(:status_options, status_options)
      |> assign(:target_is_procedure?, target_is_procedure?)
      |> assign(:show_machine_fields?, show_machine_fields?)
      |> assign(:show_timeout_fields?, show_timeout_fields?)
      |> assign(:show_run_fields?, show_run_fields?)
      |> assign(:show_fail_fields?, show_fail_fields?)

    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <p class="app-kicker">Visual Builder</p>
          <p class="mt-2 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
            Add common sequence constructs from the current machine contract surface. Visual edits regenerate the canonical sequence source directly.
          </p>
        </div>
        <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
          subset editor
        </span>
      </div>

      <div class="mt-4 grid gap-4 xl:grid-cols-[0.75fr_1.25fr]">
        <form phx-submit="add_sequence_procedure" class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
          <div class="flex items-center justify-between gap-3">
            <p class="font-semibold text-[var(--app-text)]">Add Procedure</p>
            <button
              type="submit"
              class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
              disabled={@read_only?}
            >
              Add Procedure
            </button>
          </div>

          <div class="mt-4 grid gap-3">
            <label class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Name</span>
              <input type="text" name="procedure[name]" class="app-input w-full" placeholder="shutdown" />
            </label>
            <label class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Meaning</span>
              <input type="text" name="procedure[meaning]" class="app-input w-full" placeholder="Optional human summary" />
            </label>
          </div>
        </form>

        <form
          phx-change="change_step_builder"
          phx-submit="add_sequence_step"
          class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4"
        >
          <div class="flex items-center justify-between gap-3">
            <p class="font-semibold text-[var(--app-text)]">Add Step</p>
            <button
              type="submit"
              class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
              disabled={@read_only?}
            >
              Add Step
            </button>
          </div>

          <div class="mt-4 grid gap-3 xl:grid-cols-2">
            <label class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Target</span>
              <select name="builder[target]" class="app-input w-full">
                <option value="root" selected={@step_builder["target"] == "root"}>Root Flow</option>
                <option value="procedure" selected={@step_builder["target"] == "procedure"} disabled={@procedure_options == []}>
                  Procedure
                </option>
              </select>
            </label>

            <label :if={@target_is_procedure?} class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Target Procedure</span>
              <select name="builder[target_procedure]" class="app-input w-full">
                <option :for={procedure <- @procedure_options} value={procedure} selected={@step_builder["target_procedure"] == procedure}>
                  {procedure}
                </option>
              </select>
            </label>

            <label class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Kind</span>
              <select name="builder[kind]" class="app-input w-full">
                <option value="do_skill" selected={@step_builder["kind"] == "do_skill"}>Do Skill</option>
                <option value="wait_status" selected={@step_builder["kind"] == "wait_status"}>Wait Status</option>
                <option value="run" selected={@step_builder["kind"] == "run"}>Run Procedure</option>
                <option value="fail" selected={@step_builder["kind"] == "fail"}>Fail</option>
              </select>
            </label>

            <label :if={@show_run_fields?} class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Procedure To Run</span>
              <select name="builder[run_procedure]" class="app-input w-full">
                <option :for={procedure <- @procedure_options} value={procedure} selected={@step_builder["run_procedure"] == procedure}>
                  {procedure}
                </option>
              </select>
            </label>

            <label :if={@show_machine_fields?} class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Machine</span>
              <select name="builder[machine]" class="app-input w-full">
                <option :for={machine <- @machine_options} value={machine} selected={@step_builder["machine"] == machine}>
                  {machine}
                </option>
              </select>
            </label>

            <label :if={@step_builder["kind"] == "do_skill"} class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Skill</span>
              <select name="builder[skill]" class="app-input w-full">
                <option :for={skill <- @skill_options} value={skill} selected={@step_builder["skill"] == skill}>
                  {skill}
                </option>
              </select>
            </label>

            <label :if={@step_builder["kind"] == "wait_status"} class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Status</span>
              <select name="builder[status]" class="app-input w-full">
                <option :for={status <- @status_options} value={status} selected={@step_builder["status"] == status}>
                  {status}
                </option>
              </select>
            </label>

            <label :if={@show_timeout_fields?} class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Timeout ms</span>
              <input type="number" min="0" name="builder[timeout_ms]" value={@step_builder["timeout_ms"]} class="app-input w-full" placeholder="2000" />
            </label>

            <label :if={@show_timeout_fields? or @show_fail_fields?} class="grid gap-2 text-sm text-[var(--app-text-muted)]">
              <span>Failure Message</span>
              <input type="text" name="builder[fail_message]" value={@step_builder["fail_message"]} class="app-input w-full" placeholder="Optional failure message" />
            </label>

            <label class="grid gap-2 text-sm text-[var(--app-text-muted)] xl:col-span-2">
              <span>Meaning</span>
              <input type="text" name="builder[meaning]" value={@step_builder["meaning"]} class="app-input w-full" placeholder="Optional human summary" />
            </label>
          </div>
        </form>
      </div>
    </section>
    """
  end

  attr(:steps, :list, default: [])
  attr(:scope, :string, required: true)
  attr(:procedure, :string, default: nil)
  attr(:read_only?, :boolean, default: false)
  attr(:empty_label, :string, required: true)

  defp editable_step_list(assigns) do
    ~H"""
    <div class="mt-3 space-y-3">
      <p :if={@steps == []} class="text-sm leading-6 text-[var(--app-text-muted)]">
        {@empty_label}
      </p>

      <div :for={{step, index} <- Enum.with_index(@steps)} class="space-y-2">
        <.step_card step={step} />
        <div class="flex justify-end">
          <button
            type="button"
            phx-click="remove_sequence_step"
            phx-value-scope={@scope}
            phx-value-procedure={@procedure}
            phx-value-index={index}
            class="app-button-secondary disabled:cursor-not-allowed disabled:opacity-60"
            disabled={@read_only?}
          >
            Remove Step
          </button>
        </div>
      </div>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:value, :string, required: true)

  defp summary_card(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <p class="app-kicker">{@title}</p>
      <p class="mt-3 break-words font-mono text-[12px] leading-6 text-[var(--app-text)]">
        {@value}
      </p>
    </section>
    """
  end

  attr(:step, :map, required: true)

  defp step_card(assigns) do
    ~H"""
    <div class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-3 py-3">
      <div class="flex items-start justify-between gap-3">
        <p class="text-sm font-semibold text-[var(--app-text)]">{step_label(@step)}</p>
        <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 text-[11px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
          {humanize_step_kind(@step.kind)}
        </span>
      </div>
      <p :if={step_detail(@step)} class="mt-2 font-mono text-[12px] leading-6 text-[var(--app-text-muted)]">
        {step_detail(@step)}
      </p>
      <p :if={@step.meaning} class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
        {@step.meaning}
      </p>
    </div>
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

  defp step_label(%{kind: "do_skill", machine: machine, skill: skill}),
    do: "#{machine}.#{skill}"

  defp step_label(%{kind: kind, condition: condition})
       when kind in ["wait_status", "wait_signal"],
       do: condition

  defp step_label(%{kind: "run", procedure: procedure}), do: ":" <> procedure
  defp step_label(%{kind: "repeat"}), do: "Repeat"
  defp step_label(%{kind: "fail", message: message}), do: message

  defp step_detail(%{kind: "do_skill"} = step) do
    guard = Map.get(step, :guard)
    timeout_ms = Map.get(step, :timeout_ms)

    [guard && "when #{guard}", timeout_ms && "timeout #{timeout_ms}ms"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp step_detail(%{kind: kind} = step) when kind in ["wait_status", "wait_signal"] do
    guard = Map.get(step, :guard)
    timeout_ms = Map.get(step, :timeout_ms)
    fail_message = Map.get(step, :fail_message)

    [
      guard && "when #{guard}",
      timeout_ms && "timeout #{timeout_ms}ms",
      fail_message && "else fail #{inspect(fail_message)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp step_detail(%{kind: "run"} = step) do
    case Map.get(step, :guard) do
      guard when is_binary(guard) -> "when #{guard}"
      _ -> nil
    end
  end

  defp step_detail(%{kind: "repeat"} = step) do
    case Map.get(step, :guard) do
      guard when is_binary(guard) -> "when #{guard}"
      _ -> nil
    end
  end

  defp step_detail(_step), do: nil

  defp humanize_step_kind("do_skill"), do: "Do"
  defp humanize_step_kind("wait_status"), do: "Wait"
  defp humanize_step_kind("wait_signal"), do: "Wait Signal"
  defp humanize_step_kind("run"), do: "Run"
  defp humanize_step_kind("repeat"), do: "Loop"
  defp humanize_step_kind("fail"), do: "Fail"

  defp empty_contract_context do
    %{topology: nil, machines: [], diagnostics: []}
  end

  defp contract_context(_assigns, nil), do: empty_contract_context()

  defp contract_context(assigns, %{topology_module_name: topology_module_name})
       when is_binary(topology_module_name) do
    with {:ok, topology_model} <- load_topology_model(assigns, topology_module_name) do
      machine_contracts = load_machine_contracts(assigns)

      %{
        topology: %{
          module_name: topology_model.module_name,
          topology_id: topology_model.topology_id,
          meaning: topology_model.meaning
        },
        machines:
          Enum.map(topology_model.machines, &machine_contract(&1, machine_contracts, assigns)),
        diagnostics: []
      }
    else
      {:error, message} ->
        %{topology: nil, machines: [], diagnostics: [message]}
    end
  end

  defp contract_context(_assigns, _model), do: empty_contract_context()

  defp load_topology_model(assigns, topology_module_name) do
    SessionSync.list_entries(assigns, :topology)
    |> Enum.find(&(draft_module_name(&1) == topology_module_name))
    |> topology_model_from_entry(topology_module_name)
  end

  defp topology_model_from_entry(nil, topology_module_name) do
    {:error,
     "The workspace session does not contain topology #{topology_module_name}, so the sequence contract surface cannot be derived."}
  end

  defp topology_model_from_entry(%{model: model}, _topology_module_name) when is_map(model),
    do: {:ok, model}

  defp topology_model_from_entry(%{source: source}, topology_module_name)
       when is_binary(source) do
    case TopologySource.contract_projection_from_source(source) do
      {:ok, model} ->
        {:ok, model}

      {:error, diagnostics} ->
        {:error,
         "Topology #{topology_module_name} could not be recovered for contract browsing: #{List.first(diagnostics)}"}
    end
  end

  defp load_machine_contracts(assigns) do
    SessionSync.list_entries(assigns, :machine)
    |> Enum.reduce(%{}, fn draft, acc ->
      case loaded_machine_contract(draft_module_name(draft)) do
        {nil, _contract} ->
          acc

        {_module_name, nil} ->
          acc

        {module_name, contract} ->
          Map.put(acc, module_name, contract)
      end
    end)
  end

  defp machine_contract(machine, machine_contracts, assigns) do
    case Map.fetch(machine_contracts, machine.module_name) do
      {:ok, contract} ->
        %{
          name: machine.name,
          module_name: machine.module_name,
          meaning: contract.meaning || machine.meaning,
          skills: contract.skills,
          status: contract.status,
          signals: contract.signals,
          diagnostics: []
        }

      :error ->
        %{
          name: machine.name,
          module_name: machine.module_name,
          meaning: machine.meaning,
          skills: [],
          status: [],
          signals: [],
          diagnostics: [machine_contract_diagnostic(assigns, machine.name, machine.module_name)]
        }
    end
  end

  defp draft_module_name(%{model: %{module_name: module_name}}) when is_binary(module_name),
    do: module_name

  defp draft_module_name(%{source: source}) when is_binary(source) do
    case MachineSource.module_from_source(source) do
      {:ok, module} ->
        module
        |> Atom.to_string()
        |> String.trim_leading("Elixir.")

      {:error, _} ->
        nil
    end
  end

  defp draft_module_name(_draft), do: nil

  defp loaded_machine_contract(module_name) when is_binary(module_name) do
    contract =
      case Session.machine_contract(module_name) do
        {:ok, contract} -> contract
        _ -> nil
      end

    {module_name, contract}
  end

  defp loaded_machine_contract(module_name), do: {module_name, nil}

  defp machine_contract_diagnostic(_assigns, machine_name, module_name) do
    "Machine #{machine_name} (#{module_name}) could not expose a contract from the current workspace runtime surface."
  end

  defp current_runtime_status(nil), do: SequenceCell.default_runtime_status()

  defp current_runtime_status(sequence_id) when is_binary(sequence_id) do
    with {:ok, status} <- Session.runtime_status(:sequence, sequence_id) do
      status
    else
      _ -> SequenceCell.default_runtime_status()
    end
  end

  defp current_sequence_cell(assigns) do
    assigns
    |> SequenceCell.facts_from_assigns()
    |> then(&StudioCellModel.derive(SequenceCell, &1))
  end

  defp current_sequence_action(assigns, transition) do
    assigns
    |> current_sequence_cell()
    |> StudioCellModel.action_for_transition(transition)
  end

  defp current_compiled_model(nil, _source), do: nil

  defp current_compiled_model(sequence_id, source)
       when is_binary(sequence_id) and is_binary(source) do
    source_digest = Build.digest(source)

    with {:ok, %{source_digest: ^source_digest}} <- Session.runtime_status(:sequence, sequence_id),
         {:ok, module} <- Session.runtime_current(:sequence, sequence_id),
         true <- function_exported?(module, :__ogol_sequence__, 0) do
      module.__ogol_sequence__()
    else
      _ -> nil
    end
  end

  defp persist_visual_model(socket, model, builder_override \\ nil) do
    source = SequenceSource.to_source(model)

    {parsed_model, sync_state, diagnostics} =
      case SequenceSource.from_source(source) do
        {:ok, parsed_model} -> {parsed_model, :synced, []}
        {:error, diagnostics} -> {nil, :unsupported, diagnostics}
      end

    draft =
      Session.save_sequence_source(
        socket.assigns.sequence_id,
        source,
        parsed_model,
        sync_state,
        diagnostics
      )

    contract_context = contract_context(socket.assigns, parsed_model)
    runtime_status = current_runtime_status(socket.assigns.sequence_id)

    socket
    |> assign(:sequence_draft, draft)
    |> assign(:sequence_model, parsed_model)
    |> assign(:contract_context, contract_context)
    |> assign(:draft_source, source)
    |> assign(:current_source_digest, Build.digest(source))
    |> assign(:sync_state, sync_state)
    |> assign(:sync_diagnostics, diagnostics)
    |> assign(:runtime_status, runtime_status)
    |> assign(:compiled_model, current_compiled_model(socket.assigns.sequence_id, source))
    |> assign(:step_builder, step_builder_for(socket.assigns, parsed_model, builder_override))
    |> assign(:sequence_issue, nil)
  end

  defp add_procedure_to_model(nil, _params), do: {:error, "No sequence model is loaded."}

  defp add_procedure_to_model(model, %{"name" => name} = params) do
    name = normalize_identifier(name)
    meaning = blank_to_nil(Map.get(params, "meaning"))

    cond do
      name == "" ->
        {:error, "Procedure name is required."}

      Enum.any?(Map.get(model, :procedures, []), &(&1.name == name)) ->
        {:error, "Procedure #{name} already exists."}

      true ->
        {:ok,
         update_in(model.procedures, fn procedures ->
           procedures ++ [%{name: name, meaning: meaning, steps: []}]
         end)}
    end
  end

  defp add_step_to_model(nil, _builder), do: {:error, "No sequence model is loaded."}

  defp add_step_to_model(model, builder) do
    with {:ok, step} <- build_step(builder),
         {:ok, updated_model} <- append_step(model, builder, step) do
      {:ok, updated_model}
    end
  end

  defp build_step(%{"kind" => "do_skill", "machine" => machine, "skill" => skill} = builder)
       when machine != "" and skill != "" do
    {:ok,
     %{
       kind: "do_skill",
       machine: machine,
       skill: skill,
       guard: nil,
       timeout_ms: nil,
       meaning: blank_to_nil(Map.get(builder, "meaning"))
     }}
  end

  defp build_step(%{"kind" => "wait_status", "machine" => machine, "status" => status} = builder)
       when machine != "" and status != "" do
    with {:ok, timeout_ms} <- parse_optional_timeout(Map.get(builder, "timeout_ms")) do
      {:ok,
       %{
         kind: "wait_status",
         condition: "Ref.status(:#{machine}, :#{status})",
         guard: nil,
         timeout_ms: timeout_ms,
         fail_message: blank_to_nil(Map.get(builder, "fail_message")),
         meaning: blank_to_nil(Map.get(builder, "meaning"))
       }}
    end
  end

  defp build_step(%{"kind" => "run", "run_procedure" => procedure} = builder)
       when procedure != "" do
    {:ok,
     %{
       kind: "run",
       procedure: procedure,
       guard: nil,
       meaning: blank_to_nil(Map.get(builder, "meaning"))
     }}
  end

  defp build_step(%{"kind" => "fail"} = builder) do
    case blank_to_nil(Map.get(builder, "fail_message")) do
      nil ->
        {:error, "Fail steps need a failure message."}

      message ->
        {:ok,
         %{kind: "fail", message: message, meaning: blank_to_nil(Map.get(builder, "meaning"))}}
    end
  end

  defp build_step(%{"kind" => kind}) do
    {:error, "Visual builder does not yet support #{kind}."}
  end

  defp build_step(_builder), do: {:error, "Step configuration is incomplete."}

  defp append_step(model, %{"target" => "procedure", "target_procedure" => procedure}, step) do
    case Enum.find_index(model.procedures, &(&1.name == procedure)) do
      nil ->
        {:error, "Choose a target procedure before adding a step."}

      index ->
        {:ok,
         update_in(model.procedures, fn procedures ->
           List.update_at(procedures, index, fn proc ->
             Map.update!(proc, :steps, &(&1 ++ [step]))
           end)
         end)}
    end
  end

  defp append_step(model, _builder, step) do
    {:ok, update_in(model.root_steps, &(&1 ++ [step]))}
  end

  defp remove_step_from_model(nil, _scope, _procedure, _index),
    do: {:error, "No sequence model is loaded."}

  defp remove_step_from_model(model, "root", _procedure, index) do
    with {:ok, index} <- parse_index(index),
         true <- index < length(model.root_steps) do
      {:ok, update_in(model.root_steps, &List.delete_at(&1, index))}
    else
      _ -> {:error, "The selected root step could not be removed."}
    end
  end

  defp remove_step_from_model(model, "procedure", procedure, index) do
    with {:ok, index} <- parse_index(index),
         procedure when is_binary(procedure) <- procedure,
         proc_index when is_integer(proc_index) <-
           Enum.find_index(model.procedures, &(&1.name == procedure)),
         true <- index < length(Enum.at(model.procedures, proc_index).steps) do
      {:ok,
       update_in(model.procedures, fn procedures ->
         List.update_at(procedures, proc_index, fn proc ->
           Map.update!(proc, :steps, &List.delete_at(&1, index))
         end)
       end)}
    else
      _ -> {:error, "The selected procedure step could not be removed."}
    end
  end

  defp remove_step_from_model(_model, _scope, _procedure, _index) do
    {:error, "The selected step could not be removed."}
  end

  defp remove_procedure_from_model(nil, _procedure), do: {:error, "No sequence model is loaded."}

  defp remove_procedure_from_model(model, procedure) when is_binary(procedure) do
    if Enum.any?(model.procedures, &(&1.name == procedure)) do
      updated_model = %{
        model
        | procedures: Enum.reject(model.procedures, &(&1.name == procedure)),
          root_steps: remove_procedure_runs(model.root_steps, procedure)
      }

      {:ok,
       update_in(updated_model.procedures, fn procedures ->
         Enum.map(procedures, fn proc ->
           Map.update!(proc, :steps, &remove_procedure_runs(&1, procedure))
         end)
       end)}
    else
      {:error, "Procedure #{procedure} does not exist."}
    end
  end

  defp remove_procedure_runs(steps, procedure) do
    Enum.reject(steps, &match?(%{kind: "run", procedure: ^procedure}, &1))
  end

  defp step_builder_for(assigns, sequence_model, current_builder \\ %{}) do
    contract_context = contract_context(assigns, sequence_model)
    normalize_step_builder(current_builder, contract_context, sequence_model)
  end

  defp normalize_step_builder(params, contract_context, sequence_model) do
    params = stringify_builder_keys(params)
    machine_options = builder_machine_options(contract_context)
    procedure_options = builder_procedure_options(sequence_model)

    target =
      normalize_choice(
        Map.get(params, "target", if(procedure_options == [], do: "root", else: "root")),
        ["root", "procedure"]
      )

    target =
      if target == "procedure" and procedure_options == [] do
        "root"
      else
        target
      end

    kind =
      normalize_choice(Map.get(params, "kind", "do_skill"), [
        "do_skill",
        "wait_status",
        "run",
        "fail"
      ])

    machine = normalize_existing(Map.get(params, "machine"), machine_options)

    skill =
      normalize_existing(
        Map.get(params, "skill"),
        builder_skill_options(contract_context, %{"machine" => machine})
      )

    status =
      normalize_existing(
        Map.get(params, "status"),
        builder_status_options(contract_context, %{"machine" => machine})
      )

    target_procedure = normalize_existing(Map.get(params, "target_procedure"), procedure_options)
    run_procedure = normalize_existing(Map.get(params, "run_procedure"), procedure_options)

    %{
      "target" => target,
      "target_procedure" => target_procedure,
      "kind" => kind,
      "machine" => machine,
      "skill" => skill,
      "status" => status,
      "run_procedure" => run_procedure,
      "timeout_ms" => Map.get(params, "timeout_ms", ""),
      "fail_message" => Map.get(params, "fail_message", ""),
      "meaning" => Map.get(params, "meaning", "")
    }
  end

  defp empty_step_builder do
    %{
      "target" => "root",
      "target_procedure" => "",
      "kind" => "do_skill",
      "machine" => "",
      "skill" => "",
      "status" => "",
      "run_procedure" => "",
      "timeout_ms" => "",
      "fail_message" => "",
      "meaning" => ""
    }
  end

  defp stringify_builder_keys(params) when is_map(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_builder_keys(_other), do: %{}

  defp builder_machine_options(%{machines: machines}) do
    machines
    |> Enum.filter(&(has_contract_items?(&1.skills) or has_contract_items?(&1.status)))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp builder_machine_options(_context), do: []

  defp builder_procedure_options(nil), do: []
  defp builder_procedure_options(%{procedures: procedures}), do: Enum.map(procedures, & &1.name)

  defp builder_skill_options(%{machines: machines}, %{"machine" => machine}) do
    machines
    |> Enum.find(&(&1.name == machine))
    |> case do
      %{skills: skills} -> Enum.map(skills, & &1.name)
      _ -> []
    end
  end

  defp builder_skill_options(_context, _builder), do: []

  defp builder_status_options(%{machines: machines}, %{"machine" => machine}) do
    machines
    |> Enum.find(&(&1.name == machine))
    |> case do
      %{status: status} -> Enum.map(status, & &1.name)
      _ -> []
    end
  end

  defp builder_status_options(_context, _builder), do: []

  defp has_contract_items?(items) when is_list(items), do: items != []
  defp has_contract_items?(_items), do: false

  defp normalize_choice(value, allowed) do
    if Enum.member?(allowed, value) do
      value
    else
      case allowed do
        [default | _] -> default
        [] -> ""
      end
    end
  end

  defp normalize_existing(value, options) when is_binary(value) do
    if value in options do
      value
    else
      List.first(options) || ""
    end
  end

  defp normalize_existing(_value, options), do: List.first(options) || ""

  defp parse_optional_timeout(nil), do: {:ok, nil}
  defp parse_optional_timeout(""), do: {:ok, nil}

  defp parse_optional_timeout(value) when is_binary(value) do
    case Integer.parse(value) do
      {timeout, ""} when timeout >= 0 -> {:ok, timeout}
      _ -> {:error, "Timeout must be a non-negative integer."}
    end
  end

  defp parse_optional_timeout(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp parse_optional_timeout(_other), do: {:error, "Timeout must be a non-negative integer."}

  defp parse_index(index) when is_binary(index) do
    case Integer.parse(index) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> :error
    end
  end

  defp parse_index(index) when is_integer(index) and index >= 0, do: {:ok, index}
  defp parse_index(_other), do: :error

  defp normalize_identifier(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/u, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value
end
