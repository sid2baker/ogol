defmodule Ogol.HMIWeb.TopologyStudioLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMIWeb.Components.StudioCell
  alias Ogol.HMIWeb.StudioRevision
  alias Ogol.Topology.Source, as: TopologySource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell
  alias Ogol.Studio.Modules
  alias Ogol.Studio.TopologyCell
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.TopologyRuntime

  @views [:visual, :source]
  @strategies [
    {"One For One", "one_for_one"},
    {"One For All", "one_for_all"},
    {"Rest For One", "rest_for_one"}
  ]
  @restart_policies [
    {"Permanent", "permanent"},
    {"Transient", "transient"},
    {"Temporary", "temporary"}
  ]
  @observation_kinds [
    {"Signal", "signal"},
    {"State", "state"},
    {"Status", "status"},
    {"Down", "down"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Topology Studio")
     |> assign(
       :page_summary,
       "Author canonical topology modules over a constrained visual subset, compile them into the selected runtime, and start or stop the active topology explicitly."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :topology)
     |> assign(:requested_view, :visual)
     |> assign(:requested_topology_id, nil)
     |> assign(:studio_feedback, nil)
     |> assign(:strategies, @strategies)
     |> assign(:restart_policies, @restart_policies)
     |> assign(:observation_kinds, @observation_kinds)
     |> StudioRevision.subscribe()
     |> load_topology()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> StudioRevision.apply_param(params)
     |> assign(:requested_topology_id, normalize_requested_topology_id(params["topology"]))
     |> load_topology()}
  end

  @impl true
  def handle_info({:workspace_updated, _operation, _reply, _session}, socket) do
    {:noreply,
     socket
     |> StudioRevision.sync_session()
     |> load_topology()}
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

  def handle_event("add_topology_machine", _params, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_topology(socket)}
    else
      draft = WorkspaceStore.create_machine()

      visual_form =
        socket.assigns.visual_form
        |> append_machine_row(draft)

      {:noreply,
       socket
       |> assign(:machine_catalog, machine_catalog())
       |> persist_visual_form(visual_form)}
    end
  end

  def handle_event("remove_topology_machine", %{"index" => index}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_topology(socket)}
    else
      {:noreply,
       persist_visual_form(socket, remove_machine_row(socket.assigns.visual_form, index))}
    end
  end

  def handle_event("request_transition", %{"transition" => "start"}, socket) do
    if socket.assigns.current_source_digest != socket.assigns.runtime_status.source_digest do
      {:noreply,
       assign(
         socket,
         :studio_feedback,
         feedback(
           :warning,
           "Start blocked",
           "Compile the current topology source before starting it."
         )
       )}
    else
      case WorkspaceStore.start_topology(socket.assigns.topology_id) do
        {:ok, _result} ->
          {:noreply,
           socket
           |> assign(
             :runtime_status,
             current_runtime_status(
               socket.assigns.topology_id,
               socket.assigns.draft_source,
               socket.assigns.topology_model
             )
           )
           |> assign(:studio_feedback, nil)}

        {:blocked, %{pids: pids}} ->
          {:noreply,
           socket
           |> assign(
             :runtime_status,
             current_runtime_status(
               socket.assigns.topology_id,
               socket.assigns.draft_source,
               socket.assigns.topology_model
             )
           )
           |> assign(
             :studio_feedback,
             feedback(
               :warning,
               "Start blocked",
               "Old code is still draining in #{length(pids)} process(es). Retry once they leave the previous topology module."
             )
           )}

        {:error, :already_running} ->
          {:noreply,
           socket
           |> assign(
             :runtime_status,
             current_runtime_status(
               socket.assigns.topology_id,
               socket.assigns.draft_source,
               socket.assigns.topology_model
             )
           )
           |> assign(:studio_feedback, nil)}

        {:error, {:topology_already_running, active}} ->
          {:noreply,
           socket
           |> assign(
             :runtime_status,
             current_runtime_status(
               socket.assigns.topology_id,
               socket.assigns.draft_source,
               socket.assigns.topology_model
             )
           )
           |> assign(
             :studio_feedback,
             feedback(
               :warning,
               "Another topology is active",
               "#{humanize_id(Atom.to_string(active.root))} is already running. Stop it before starting this topology."
             )
           )}

        {:error, {:machine_module_not_available, module_name}} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :error,
               "Start failed",
               "Referenced machine module #{module_name} is not available yet."
             )
           )}

        {:error, {:machine_build_failed, machine_id, diagnostics}} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :error,
               "Machine build failed",
               "Referenced machine #{machine_id} failed to build: #{format_diagnostic(List.first(List.wrap(diagnostics)))}"
             )
           )}

        {:error, {:machine_apply_failed, machine_id, reason}} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :error,
               "Machine apply failed",
               "Referenced machine #{machine_id} could not be applied: #{inspect(reason)}"
             )
           )}

        {:error, {:invalid_topology, detail}} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(:error, "Start failed", detail)
           )}

        {:error, :ethercat_master_not_running} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :warning,
               "Start blocked",
               "Start the EtherCAT master before starting this topology."
             )
           )}

        {:error, :module_not_found} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :error,
               "Start failed",
               "Source must define one topology module before it can be started."
             )
           )}

        {:error, {:module_not_current, :topology, _id}} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :warning,
               "Start blocked",
               "Compile the current topology source before starting it."
             )
           )}

        {:error, {:module_blocked, :topology, _id, reason}} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :error,
               "Start failed",
               "The compiled topology module is blocked in the runtime: #{inspect(reason)}"
             )
           )}

        {:error, %{diagnostics: diagnostics}} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :error,
               "Build failed",
               "Resolve compile diagnostics before starting this topology: #{format_diagnostic(List.first(List.wrap(diagnostics)))}"
             )
           )}

        {:error, reason} ->
          {:noreply,
           assign(
             socket,
             :studio_feedback,
             feedback(
               :error,
               "Start failed",
               "Topology runtime rejected the current source: #{inspect(reason)}"
             )
           )}
      end
    end
  end

  def handle_event("request_transition", %{"transition" => "compile"}, socket) do
    case WorkspaceStore.compile_topology(socket.assigns.topology_id) do
      {:ok, draft} ->
        {:noreply,
         socket
         |> assign(:topology_draft, draft)
         |> assign(
           :runtime_status,
           current_runtime_status(
             socket.assigns.topology_id,
             socket.assigns.draft_source,
             socket.assigns.topology_model
           )
         )
         |> assign(:studio_feedback, nil)}

      {:error, diagnostics, draft} when is_list(diagnostics) ->
        {:noreply,
         socket
         |> assign(:topology_draft, draft)
         |> assign(:studio_feedback, nil)}

      {:error, :module_not_found, draft} ->
        {:noreply,
         socket
         |> assign(:topology_draft, draft)
         |> assign(:studio_feedback, nil)}
    end
  end

  def handle_event("request_transition", %{"transition" => "stop"}, socket) do
    case WorkspaceStore.stop_topology(socket.assigns.topology_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           :runtime_status,
           current_runtime_status(
             socket.assigns.topology_id,
             socket.assigns.draft_source,
             socket.assigns.topology_model
           )
         )
         |> assign(:studio_feedback, nil)}

      {:error, :not_running} ->
        {:noreply,
         socket
         |> assign(
           :runtime_status,
           current_runtime_status(
             socket.assigns.topology_id,
             socket.assigns.draft_source,
             socket.assigns.topology_model
           )
         )
         |> assign(:studio_feedback, nil)}

      {:error, {:different_topology_running, active}} ->
        {:noreply,
         assign(
           socket,
           :studio_feedback,
           feedback(
             :warning,
             "Stop blocked",
             "#{humanize_id(Atom.to_string(active.root))} is active, not the selected topology."
           )
         )}

      {:error, reason} ->
        {:noreply,
         assign(
           socket,
           :studio_feedback,
           feedback(
             :error,
             "Stop failed",
             "Topology runtime could not be stopped: #{inspect(reason)}"
           )
         )}
    end
  end

  def handle_event("change_visual", %{"topology" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_topology(socket)}
    else
      visual_form = normalize_visual_form(params, socket.assigns.visual_form)
      {:noreply, persist_visual_form(socket, visual_form)}
    end
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_topology(socket)}
    else
      {model, sync_state, diagnostics} =
        case TopologySource.from_source(source) do
          {:ok, model} ->
            {model, :synced, []}

          {:error, diagnostics} ->
            {nil, :unsupported, diagnostics}
        end

      draft =
        WorkspaceStore.save_topology_source(
          socket.assigns.topology_id,
          source,
          model,
          sync_state,
          diagnostics
        )

      {:noreply,
       socket
       |> assign(:topology_draft, draft)
       |> assign(:topology_model, model)
       |> assign(:draft_source, source)
       |> assign(:current_source_digest, Build.digest(source))
       |> assign(
         :runtime_status,
         current_runtime_status(socket.assigns.topology_id, source, model)
       )
       |> assign(
         :visual_form,
         (model && TopologySource.form_from_model(model)) || socket.assigns.visual_form
       )
       |> assign(:sync_state, sync_state)
       |> assign(:sync_diagnostics, normalize_sync_diagnostics(diagnostics))
       |> assign(:validation_errors, [])
       |> assign(:studio_feedback, nil)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      if assigns.topology_draft do
        topology_facts = TopologyCell.facts_from_assigns(assigns)

        assigns
        |> assign(:topology_cell, Cell.derive(TopologyCell, topology_facts))
        |> assign(:root_machine_options, root_machine_options(assigns.visual_form))
        |> assign(:observation_source_options, root_machine_options(assigns.visual_form))
        |> assign(
          :machine_module_options,
          machine_module_options(assigns.machine_catalog, assigns.visual_form)
        )
      else
        assigns
        |> assign(:topology_cell, nil)
        |> assign(:root_machine_options, [])
        |> assign(:observation_source_options, [])
        |> assign(:machine_module_options, [])
      end

    ~H"""
    <section class="grid gap-5">
      <StudioCell.cell :if={@topology_draft} body_class="min-h-[72rem]">
        <:actions>
          <StudioCell.action_button
            :for={action <- @topology_cell.actions}
            type="button"
            phx-click="request_transition"
            phx-value-transition={action.id}
            phx-disable-with={if(action.id == :start, do: "Starting...", else: nil)}
            variant={action.variant}
            disabled={!action.enabled?}
            title={action.disabled_reason}
          >
            {action.label}
          </StudioCell.action_button>
        </:actions>

        <:notice :if={@topology_cell.notice}>
          <StudioCell.notice
            tone={@topology_cell.notice.tone}
            title={@topology_cell.notice.title}
            message={@topology_cell.notice.message}
          />
        </:notice>

        <:views>
          <StudioCell.view_button
            :for={view <- @topology_cell.views}
            type="button"
            phx-click="select_view"
            phx-value-view={view.id}
            selected={@topology_cell.selected_view == view.id}
            available={view.available?}
            data-test={"topology-view-#{view.id}"}
          >
            {view.label}
          </StudioCell.view_button>
        </:views>

        <:body>
          <.visual_editor
            :if={@topology_cell.selected_view == :visual}
            visual_form={@visual_form}
            machine_module_options={@machine_module_options}
            strategies={@strategies}
            restart_policies={@restart_policies}
            observation_kinds={@observation_kinds}
            root_machine_options={@root_machine_options}
            observation_source_options={@observation_source_options}
            read_only?={@studio_read_only?}
          />

          <.source_editor
            :if={@topology_cell.selected_view == :source}
            draft_source={@draft_source}
            read_only?={@studio_read_only?}
          />
        </:body>
      </StudioCell.cell>

      <section :if={!@topology_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Topology</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          The current bundle does not contain a topology
        </h2>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          Import a bundle that includes a topology to configure composition and runtime start/stop from this page.
        </p>
      </section>
    </section>
    """
  end

  defp load_topology(socket) do
    {topology_id, draft, model, machine_catalog} = topology_snapshot(socket.assigns)

    if draft do
      sync_diagnostics = normalize_sync_diagnostics(draft.sync_diagnostics)

      socket
      |> assign(:topology_id, topology_id)
      |> assign(:topology_draft, draft)
      |> assign(:machine_catalog, machine_catalog)
      |> assign(:topology_model, model)
      |> assign(:runtime_status, current_runtime_status(topology_id, draft.source, model))
      |> assign(:current_source_digest, Build.digest(draft.source))
      |> assign(
        :visual_form,
        (model && TopologySource.form_from_model(model)) ||
          TopologySource.form_from_model(TopologySource.default_model(topology_id))
      )
      |> assign(:draft_source, draft.source)
      |> assign(:sync_state, draft.sync_state)
      |> assign(:sync_diagnostics, sync_diagnostics)
      |> assign(:validation_errors, [])
      |> assign(:studio_feedback, nil)
    else
      socket
      |> assign(:topology_id, nil)
      |> assign(:topology_draft, nil)
      |> assign(:machine_catalog, machine_catalog)
      |> assign(:topology_model, nil)
      |> assign(
        :runtime_status,
        TopologyCell.default_runtime_status()
      )
      |> assign(
        :visual_form,
        TopologySource.form_from_model(TopologySource.default_model("topology"))
      )
      |> assign(:draft_source, "")
      |> assign(:current_source_digest, Build.digest(""))
      |> assign(:sync_state, :synced)
      |> assign(:sync_diagnostics, [])
      |> assign(:validation_errors, [])
      |> assign(:studio_feedback, nil)
    end
  end

  defp topology_snapshot(assigns) do
    drafts = WorkspaceStore.list_topologies()
    draft = select_topology_draft(drafts, assigns[:requested_topology_id])

    model =
      if draft do
        draft.model ||
          case TopologySource.from_source(draft.source) do
            {:ok, parsed_model} -> parsed_model
            {:error, _diagnostics} -> nil
          end
      end

    {draft && draft.id, draft, model, machine_catalog()}
  end

  defp normalize_requested_topology_id(nil), do: nil
  defp normalize_requested_topology_id(""), do: nil
  defp normalize_requested_topology_id(value) when is_binary(value), do: value
  defp normalize_requested_topology_id(_other), do: nil

  defp select_topology_draft(drafts, requested_id) do
    Enum.find(drafts, &(&1.id == requested_id)) ||
      Enum.find(drafts, &(&1.id == WorkspaceStore.topology_default_id())) ||
      List.first(Enum.sort_by(drafts, & &1.id))
  end

  defp machine_catalog do
    WorkspaceStore.list_machines()
    |> Enum.map(fn draft ->
      label =
        case draft.model do
          %{meaning: meaning} when is_binary(meaning) and meaning != "" -> meaning
          _ -> humanize_id(draft.id)
        end

      %{
        id: draft.id,
        label: label,
        module_name:
          case draft.model do
            %{module_name: module_name} -> module_name
            _ -> "Ogol.Generated.Machines.#{Macro.camelize(draft.id)}"
          end
      }
    end)
  end

  defp root_machine_options(visual_form) do
    visual_form
    |> Map.get("machines", %{})
    |> Map.values()
    |> Enum.map(fn row -> Map.get(row, "name", "") end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_visual_form(params, existing_form) do
    existing_form
    |> Map.merge(params)
    |> Map.update("topology_id", existing_form["topology_id"], &to_string/1)
    |> Map.update("module_name", existing_form["module_name"], &to_string/1)
    |> Map.update("root_machine", existing_form["root_machine"], &to_string/1)
    |> Map.update("strategy", existing_form["strategy"], &to_string/1)
    |> Map.update("meaning", existing_form["meaning"], &to_string/1)
  end

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp persist_visual_form(socket, visual_form) do
    case TopologySource.cast_model(visual_form) do
      {:ok, model} ->
        source = TopologySource.to_source(model)

        draft =
          WorkspaceStore.save_topology_source(
            socket.assigns.topology_id,
            source,
            model,
            :synced,
            []
          )

        socket
        |> assign(:topology_draft, draft)
        |> assign(:topology_model, model)
        |> assign(:visual_form, TopologySource.form_from_model(model))
        |> assign(:draft_source, source)
        |> assign(:current_source_digest, Build.digest(source))
        |> assign(
          :runtime_status,
          current_runtime_status(socket.assigns.topology_id, source, model)
        )
        |> assign(:sync_state, :synced)
        |> assign(:sync_diagnostics, [])
        |> assign(:validation_errors, [])
        |> assign(:studio_feedback, nil)

      {:error, errors} ->
        socket
        |> assign(:visual_form, visual_form)
        |> assign(:validation_errors, errors)
        |> assign(:studio_feedback, nil)
    end
  end

  defp append_machine_row(visual_form, draft) do
    rows =
      visual_form
      |> Map.get("machines", %{})
      |> indexed_rows()
      |> Kernel.++([
        %{
          "name" => draft.id,
          "module_name" => machine_module_name(draft),
          "restart" => "permanent",
          "meaning" => machine_meaning(draft)
        }
      ])

    visual_form
    |> Map.put("machines", indexed_map(rows))
    |> Map.put("machine_count", Integer.to_string(length(rows)))
  end

  defp remove_machine_row(visual_form, index) do
    rows =
      visual_form
      |> Map.get("machines", %{})
      |> indexed_rows()
      |> drop_row(index)

    rows =
      case rows do
        [] -> indexed_rows(Map.get(visual_form, "machines", %{}))
        _ -> rows
      end

    root_machine =
      case Enum.find(rows, fn row -> row["name"] == visual_form["root_machine"] end) do
        nil -> rows |> List.first() |> then(&((&1 && &1["name"]) || visual_form["root_machine"]))
        _row -> visual_form["root_machine"]
      end

    visual_form
    |> Map.put("machines", indexed_map(rows))
    |> Map.put("machine_count", Integer.to_string(length(rows)))
    |> Map.put("root_machine", root_machine)
  end

  defp indexed_rows(rows) do
    rows
    |> Enum.sort_by(fn {key, _value} -> String.to_integer(to_string(key)) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp drop_row(rows, index) when is_binary(index) do
    case Integer.parse(index) do
      {int, ""} -> drop_row(rows, int)
      _ -> rows
    end
  end

  defp drop_row(rows, index) when is_integer(index) do
    rows
    |> Enum.with_index()
    |> Enum.reject(fn {_row, current_index} -> current_index == index end)
    |> Enum.map(&elem(&1, 0))
  end

  defp machine_module_name(%{model: %{module_name: module_name}}), do: module_name
  defp machine_module_name(%{id: id}), do: "Ogol.Generated.Machines.#{Macro.camelize(id)}"

  defp machine_meaning(%{model: %{meaning: meaning}}) when is_binary(meaning), do: meaning
  defp machine_meaning(_draft), do: ""

  defp indexed_map(rows) do
    rows
    |> Enum.with_index()
    |> Map.new(fn {row, index} -> {Integer.to_string(index), row} end)
  end

  defp current_runtime_status(topology_id, source, model) do
    topology_status = TopologyRuntime.status(source, model)

    module_status =
      case Modules.status(Modules.runtime_id(:topology, topology_id)) do
        {:ok, status} -> status
        {:error, :not_found} -> %{source_digest: nil, blocked_reason: nil, lingering_pids: []}
      end

    Map.merge(topology_status, %{
      source_digest: module_status.source_digest,
      blocked_reason: module_status.blocked_reason,
      lingering_pids: module_status.lingering_pids
    })
  end

  defp feedback(level, title, detail), do: %{level: level, title: title, detail: detail}

  defp format_diagnostic(nil), do: "unknown diagnostic"
  defp format_diagnostic(%{message: message}) when is_binary(message), do: message
  defp format_diagnostic(other), do: inspect(other)

  defp normalize_sync_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.map(&format_diagnostic/1)
  end

  attr(:visual_form, :map, required: true)
  attr(:machine_module_options, :list, required: true)
  attr(:strategies, :list, required: true)
  attr(:restart_policies, :list, required: true)
  attr(:observation_kinds, :list, required: true)
  attr(:root_machine_options, :list, required: true)
  attr(:observation_source_options, :list, required: true)
  attr(:read_only?, :boolean, default: false)

  defp visual_editor(assigns) do
    ~H"""
    <form phx-change="change_visual" class="grid h-full w-full content-start gap-5">
      <fieldset disabled={@read_only?} class="contents">
      <section class="grid gap-4 xl:grid-cols-4">
        <label class="space-y-2">
          <span class="app-field-label">Topology Id</span>
          <input
            type="text"
            name="topology[topology_id]"
            value={@visual_form["topology_id"]}
            class="app-input w-full"
          />
        </label>

        <label class="space-y-2 xl:col-span-2">
          <span class="app-field-label">Module Name</span>
          <input
            type="text"
            name="topology[module_name]"
            value={@visual_form["module_name"]}
            class="app-input w-full"
          />
        </label>

        <label class="space-y-2">
          <span class="app-field-label">Strategy</span>
          <select name="topology[strategy]" class="app-input w-full">
            <option :for={{label, value} <- @strategies} value={value} selected={value == @visual_form["strategy"]}>
              {label}
            </option>
          </select>
        </label>

        <label class="space-y-2 xl:col-span-2">
          <span class="app-field-label">Meaning</span>
          <input
            type="text"
            name="topology[meaning]"
            value={@visual_form["meaning"]}
            class="app-input w-full"
          />
        </label>

        <label class="space-y-2 xl:col-span-2">
          <span class="app-field-label">Root Machine</span>
          <select name="topology[root_machine]" class="app-input w-full">
            <option :for={machine_name <- @root_machine_options} value={machine_name} selected={machine_name == @visual_form["root_machine"]}>
              {machine_name}
            </option>
          </select>
        </label>
      </section>

      <.machines_section
        rows={@visual_form["machines"]}
        machine_module_options={@machine_module_options}
        restart_policies={@restart_policies}
      />

      <.observations_section
        rows={@visual_form["observations"]}
        count_field="observation_count"
        observation_kinds={@observation_kinds}
        source_options={@observation_source_options}
      />
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

  attr(:rows, :map, required: true)
  attr(:machine_module_options, :list, required: true)
  attr(:restart_policies, :list, required: true)

  defp machines_section(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <input type="hidden" name="topology[machine_count]" value={map_size(@rows)} />

      <div class="flex items-end justify-between gap-3">
        <div>
          <p class="app-kicker">Machines</p>
          <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            Bind named topology endpoints to machine modules. Available machine drafts are suggested while source remains canonical.
          </p>
        </div>
        <button type="button" phx-click="add_topology_machine" class="app-button-secondary">
          Add Machine
        </button>
      </div>

      <div class="mt-4 space-y-3">
        <div
          :for={{index, row} <- Enum.sort_by(@rows, fn {key, _row} -> String.to_integer(key) end)}
          class="rounded-2xl border border-[var(--app-border)] px-4 py-4"
        >
          <div class="flex items-start justify-between gap-3">
            <p class="app-kicker">Machine {String.to_integer(index) + 1}</p>
            <button
              :if={map_size(@rows) > 1}
              type="button"
              phx-click="remove_topology_machine"
              phx-value-index={index}
              class="app-button-secondary"
            >
              Remove
            </button>
          </div>

          <div class="mt-3 grid gap-3 xl:grid-cols-[minmax(0,0.9fr)_minmax(0,1.5fr)_minmax(0,0.7fr)_minmax(0,1fr)]">
            <label class="space-y-2">
              <span class="app-field-label">Name</span>
              <input
                type="text"
                name={"topology[machines][#{index}][name]"}
                value={row["name"]}
                class="app-input w-full"
              />
            </label>

            <label class="space-y-2">
              <span class="app-field-label">Machine Module</span>
              <select name={"topology[machines][#{index}][module_name]"} class="app-input w-full">
                <option
                  :for={option <- machine_module_options_for_row(@machine_module_options, row["module_name"])}
                  value={option.value}
                  selected={option.value == row["module_name"]}
                >
                  {option.label}
                </option>
              </select>
            </label>

            <label class="space-y-2">
              <span class="app-field-label">Restart</span>
              <select name={"topology[machines][#{index}][restart]"} class="app-input w-full">
                <option :for={{label, value} <- @restart_policies} value={value} selected={value == row["restart"]}>
                  {label}
                </option>
              </select>
            </label>

            <label class="space-y-2">
              <span class="app-field-label">Meaning</span>
              <input
                type="text"
                name={"topology[machines][#{index}][meaning]"}
                value={row["meaning"]}
                class="app-input w-full"
              />
            </label>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:rows, :map, required: true)
  attr(:count_field, :string, required: true)
  attr(:observation_kinds, :list, required: true)
  attr(:source_options, :list, required: true)

  defp observations_section(assigns) do
    ~H"""
    <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
      <div class="flex items-end justify-between gap-3">
        <div>
          <p class="app-kicker">Observations</p>
          <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
            Project downstream machine state, signals, status, or down events into the topology’s public observation surface.
          </p>
        </div>
        <label class="space-y-1 text-right">
          <span class="app-field-label">Count</span>
          <input
            type="number"
            min="0"
            max="24"
            name={"topology[#{@count_field}]"}
            value={map_size(@rows)}
            class="app-input w-24"
          />
        </label>
      </div>

      <div :if={@rows == %{}} class="mt-4 rounded-2xl border border-dashed border-[var(--app-border)] px-4 py-4 text-sm leading-6 text-[var(--app-text-muted)]">
        No observations authored yet.
      </div>

      <div class="mt-4 space-y-3">
        <div
          :for={{index, row} <- Enum.sort_by(@rows, fn {key, _row} -> String.to_integer(key) end)}
          class="grid gap-3 rounded-2xl border border-[var(--app-border)] px-4 py-4 xl:grid-cols-[minmax(0,0.8fr)_minmax(0,0.9fr)_minmax(0,0.9fr)_minmax(0,0.9fr)_minmax(0,1.2fr)]"
        >
          <label class="space-y-2">
            <span class="app-field-label">Kind</span>
            <select name={"topology[observations][#{index}][kind]"} class="app-input w-full">
              <option :for={{label, value} <- @observation_kinds} value={value} selected={value == row["kind"]}>
                {label}
              </option>
            </select>
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Source</span>
            <select name={"topology[observations][#{index}][source]"} class="app-input w-full">
              <option :for={machine_name <- @source_options} value={machine_name} selected={machine_name == row["source"]}>
                {machine_name}
              </option>
            </select>
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Item</span>
            <input
              type="text"
              name={"topology[observations][#{index}][item]"}
              value={row["item"]}
              class="app-input w-full"
              placeholder="faulted / ready / health"
            />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">As</span>
            <input
              type="text"
              name={"topology[observations][#{index}][as]"}
              value={row["as"]}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2">
            <span class="app-field-label">Meaning</span>
            <input
              type="text"
              name={"topology[observations][#{index}][meaning]"}
              value={row["meaning"]}
              class="app-input w-full"
            />
          </label>
        </div>
      </div>
    </section>
    """
  end

  defp machine_module_options(machine_catalog, visual_form) do
    base_options =
      Enum.map(machine_catalog, fn machine ->
        %{value: machine.module_name, label: "#{machine.label} (#{machine.id})"}
      end)

    visual_form
    |> Map.get("machines", %{})
    |> indexed_rows()
    |> Enum.reduce(base_options, fn row, options ->
      current_module = row["module_name"]

      if current_module in Enum.map(options, & &1.value) do
        options
      else
        options ++ [%{value: current_module, label: "#{current_module} (unlisted)"}]
      end
    end)
  end

  defp machine_module_options_for_row(options, current_module) do
    if current_module in Enum.map(options, & &1.value) do
      options
    else
      options ++ [%{value: current_module, label: "#{current_module} (unlisted)"}]
    end
  end

  defp readonly_topology(socket) do
    assign(
      socket,
      :studio_feedback,
      feedback(:warning, StudioRevision.readonly_title(), StudioRevision.readonly_message())
    )
  end
end
