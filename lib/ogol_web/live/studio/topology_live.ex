defmodule OgolWeb.Studio.TopologyLive do
  use OgolWeb, :live_view

  alias Ogol.Machine.Graph, as: MachineGraph
  alias Ogol.Machine.SkillForm, as: MachineSkillForm
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Runtime
  alias Ogol.Runtime.{Bus, CommandGateway, SnapshotStore}
  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias OgolWeb.Studio.Session, as: StudioSession
  alias Ogol.Topology.Source, as: TopologySource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell, as: StudioCellModel
  alias Ogol.Topology.Studio.Cell, as: TopologyCell
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.TopologyRuntime

  @views [:visual, :source, :live]
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

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Bus.subscribe(Bus.overview_topic())
    end

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
     |> assign(:selected_live_machine_id, nil)
     |> assign(:live_operator_feedback, nil)
     |> assign(:live_operator_feedback_ref, nil)
     |> assign(:strategies, @strategies)
     |> assign(:restart_policies, @restart_policies)
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
  def handle_info({:workspace_updated, operation, reply, _session}, socket) do
    feedback = workspace_feedback(socket.assigns.topology_id, operation, reply)

    {:noreply,
     socket
     |> StudioRevision.sync_session()
     |> load_topology()
     |> assign(:studio_feedback, feedback)}
  end

  def handle_info({:machine_snapshot_updated, _snapshot}, socket) do
    {:noreply, assign_live_projection(socket)}
  end

  def handle_info({:operator_control_result, ref, feedback}, socket) do
    if socket.assigns.live_operator_feedback_ref == ref do
      {:noreply,
       socket
       |> assign(:live_operator_feedback_ref, nil)
       |> assign(:live_operator_feedback, feedback)
       |> assign_live_projection()}
    else
      {:noreply, socket}
    end
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

  def handle_event("select_live_machine", %{"machine" => machine_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_live_machine_id, machine_id)
     |> assign(:live_operator_feedback, nil)
     |> assign_live_projection()}
  end

  def handle_event(
        "invoke_live_skill",
        %{"machine" => machine_id, "skill" => skill_name} = params,
        socket
      ) do
    form_params = Map.get(params, "args", %{})

    with {:ok, runtime} <- resolve_live_machine(socket.assigns.live_machine_instances, machine_id),
         {:ok, skill} <- resolve_live_skill(runtime, skill_name),
         {:ok, payload} <- MachineSkillForm.cast(skill, form_params) do
      ref = make_ref()
      dispatch_live_skill_async(self(), ref, runtime.machine_id, skill.name, payload)

      {:noreply,
       socket
       |> assign(:live_operator_feedback_ref, ref)
       |> assign(
         :live_operator_feedback,
         live_operator_feedback(:pending, runtime.machine_id, skill.name, :dispatching)
       )}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:live_operator_feedback_ref, nil)
         |> assign(
           :live_operator_feedback,
           live_operator_feedback(:error, machine_id, skill_name, reason)
         )}
    end
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

  def handle_event("request_transition", %{"transition" => transition}, socket)
      when transition in ["start", "compile", "stop", "restart"] do
    case current_topology_action(socket.assigns, transition) do
      nil ->
        {:noreply, socket}

      %{id: :start} = action ->
        StudioSession.reduce_action(
          socket,
          action,
          guard: &guard_compiled_topology(&1, "Start blocked"),
          after: fn socket, reply ->
            socket
            |> assign_topology_runtime_status()
            |> assign(:studio_feedback, start_feedback(reply))
            |> assign_live_projection()
          end
        )

      %{id: :restart} = action ->
        StudioSession.reduce_action(
          socket,
          action,
          guard: &guard_compiled_topology(&1, "Restart blocked"),
          after: fn socket, reply ->
            socket
            |> assign_topology_runtime_status()
            |> assign(:studio_feedback, restart_feedback(reply))
            |> assign_live_projection()
          end
        )

      %{id: :compile} = action ->
        StudioSession.reduce_action(
          socket,
          action,
          after: fn socket, reply ->
            compile_feedback =
              case reply do
                {:error, :module_not_found} ->
                  feedback(
                    :error,
                    "Compile failed",
                    "Source must define one topology module before it can be compiled."
                  )

                _other ->
                  nil
              end

            socket
            |> assign_topology_runtime_status()
            |> assign(:studio_feedback, compile_feedback)
            |> assign_live_projection()
          end
        )

      %{id: :stop} = action ->
        StudioSession.reduce_action(
          socket,
          action,
          after: fn socket, reply ->
            socket
            |> assign_topology_runtime_status()
            |> assign(:studio_feedback, stop_feedback(reply))
            |> assign_live_projection()
          end
        )
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
       |> assign(:studio_feedback, nil)
       |> assign_live_projection()}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      if assigns.topology_draft do
        topology_cell = current_topology_cell(assigns)
        display_notice = display_notice(assigns[:studio_feedback], topology_cell)

        assigns
        |> assign(:topology_cell, topology_cell)
        |> assign(:display_notice, display_notice)
        |> assign(
          :machine_module_options,
          machine_module_options(assigns.machine_catalog, assigns.visual_form)
        )
      else
        assigns
        |> assign(:topology_cell, nil)
        |> assign(:display_notice, nil)
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

        <:notice :if={@display_notice}>
          <StudioCell.notice
            tone={@display_notice.tone}
            title={@display_notice.title}
            message={@display_notice.message}
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
            read_only?={@studio_read_only?}
          />

          <.source_editor
            :if={@topology_cell.selected_view == :source}
            draft_source={@draft_source}
            read_only?={@studio_read_only?}
          />

          <.live_editor
            :if={@topology_cell.selected_view == :live}
            runtime_status={@runtime_status}
            live_machine_instances={@live_machine_instances}
            selected_live_machine={@selected_live_machine}
            selected_live_machine_diagram={@selected_live_machine_diagram}
            selected_live_machine_id={@selected_live_machine_id}
            selected_live_skills={@selected_live_skills}
            live_operator_feedback={@live_operator_feedback}
          />
        </:body>
      </StudioCell.cell>

      <section :if={!@topology_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Topology</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          The current workspace does not contain a topology
        </h2>
        <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
          Load a revision that includes a topology to configure composition and runtime start/stop from this page.
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
      |> assign_live_projection()
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
      |> assign_live_projection()
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

  defp workspace_feedback(topology_id, {:deploy_topology, topology_id}, reply) do
    start_feedback(reply)
  end

  defp workspace_feedback(topology_id, {:stop_topology, topology_id}, reply) do
    stop_feedback(reply)
  end

  defp workspace_feedback(_topology_id, _operation, _reply), do: nil

  defp start_feedback({:ok, _result}), do: nil
  defp start_feedback({:error, :already_running}), do: nil

  defp start_feedback({:blocked, %{lingering_pids: pids}}) do
    feedback(
      :warning,
      "Start blocked",
      "Old code is still draining in #{length(pids)} process(es). Retry once they leave the previous topology module."
    )
  end

  defp start_feedback({:error, {:different_topology_running, active_topology_id}})
       when is_binary(active_topology_id) do
    feedback(
      :warning,
      "Another topology is active",
      "#{humanize_id(active_topology_id)} is already running. Stop it before starting this topology."
    )
  end

  defp start_feedback({:error, {:machine_module_not_available, module_name}}) do
    feedback(
      :error,
      "Start failed",
      "Referenced machine module #{module_name} is not available yet."
    )
  end

  defp start_feedback(
         {:error, {:artifact_load_failed, {:machine, machine_id}, %{diagnostics: diagnostics}}}
       ) do
    feedback(
      :error,
      "Machine build failed",
      "Referenced machine #{machine_id} failed to build: #{format_diagnostic(List.first(List.wrap(diagnostics)))}"
    )
  end

  defp start_feedback(
         {:error, {:artifact_load_failed, {:machine, machine_id}, %{blocked_reason: reason}}}
       ) do
    feedback(
      :error,
      "Machine apply failed",
      "Referenced machine #{machine_id} could not be applied: #{inspect(reason)}"
    )
  end

  defp start_feedback({:error, :no_hardware_config_available}) do
    feedback(
      :warning,
      "Start blocked",
      "Define and compile a hardware config before starting this topology."
    )
  end

  defp start_feedback(
         {:error,
          {:artifact_load_failed, {:hardware_config, hardware_config_id},
           %{diagnostics: diagnostics}}}
       ) do
    feedback(
      :error,
      "Hardware config build failed",
      "Hardware config #{hardware_config_id} failed to build: #{format_diagnostic(List.first(List.wrap(diagnostics)))}"
    )
  end

  defp start_feedback(
         {:error,
          {:artifact_load_failed, {:hardware_config, hardware_config_id},
           %{blocked_reason: reason}}}
       ) do
    feedback(
      :error,
      "Hardware config apply failed",
      "Hardware config #{hardware_config_id} could not be applied: #{inspect(reason)}"
    )
  end

  defp start_feedback({:error, {:hardware_activation_failed, reason}}) do
    feedback(
      :error,
      "Hardware activation failed",
      "Starting this topology requires activating the current workspace hardware config first: #{inspect(reason)}"
    )
  end

  defp start_feedback(
         {:error,
          {:shutdown,
           {:failed_to_start_child, {:ogol_machine, machine_id},
            {:hardware_output_failed, {:unsupported_command, :set_output}}}}}
       ) do
    feedback(
      :error,
      "Hardware configuration mismatch",
      "Machine #{machine_id} tried to drive a hardware output, but the active hardware slave does not support set_output. Check that the selected hardware config maps the referenced slave to an output-capable driver such as EL2809."
    )
  end

  defp start_feedback(
         {:error,
          {:shutdown,
           {:failed_to_start_child, {:ogol_machine, machine_id},
            {:hardware_output_failed, reason}}}}
       ) do
    feedback(
      :error,
      "Hardware output failed",
      "Machine #{machine_id} failed while driving hardware outputs: #{inspect(reason)}"
    )
  end

  defp start_feedback({:error, {:invalid_topology, detail}}) do
    feedback(:error, "Start failed", detail)
  end

  defp start_feedback({:error, :ethercat_master_not_running}) do
    feedback(
      :warning,
      "Start blocked",
      "Hardware activation did not leave the EtherCAT master running."
    )
  end

  defp start_feedback({:error, :module_not_found}) do
    feedback(
      :error,
      "Start failed",
      "Source must define one topology module before it can be started."
    )
  end

  defp start_feedback({:error, %{diagnostics: diagnostics}}) do
    feedback(
      :error,
      "Build failed",
      "Resolve compile diagnostics before starting this topology: #{format_diagnostic(List.first(List.wrap(diagnostics)))}"
    )
  end

  defp start_feedback({:error, reason}) do
    feedback(
      :error,
      "Start failed",
      "Topology runtime rejected the current source: #{inspect(reason)}"
    )
  end

  defp restart_feedback({:ok, _result}), do: nil

  defp restart_feedback({:error, :not_running}) do
    feedback(
      :warning,
      "Restart blocked",
      "No active deployment is available to restart."
    )
  end

  defp restart_feedback(reply), do: start_feedback(reply)

  defp stop_feedback(:ok), do: nil
  defp stop_feedback({:error, :not_running}), do: nil

  defp stop_feedback({:error, :different_topology_running}) do
    feedback(
      :warning,
      "Stop blocked",
      "Another topology is active, not the selected topology."
    )
  end

  defp stop_feedback({:error, reason}) do
    feedback(
      :error,
      "Stop failed",
      "Topology runtime could not be stopped: #{inspect(reason)}"
    )
  end

  defp display_notice(%{level: level, title: title, detail: detail}, _topology_cell) do
    %{tone: feedback_tone(level), title: title, message: detail}
  end

  defp display_notice(nil, topology_cell), do: topology_cell.notice

  defp feedback_tone(:error), do: :error
  defp feedback_tone(:warning), do: :warning
  defp feedback_tone(_other), do: :info

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

  defp normalize_visual_form(params, existing_form) do
    existing_form
    |> Map.merge(params)
    |> Map.update("topology_id", existing_form["topology_id"], &to_string/1)
    |> Map.update("module_name", existing_form["module_name"], &to_string/1)
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
        |> assign_live_projection()

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

    visual_form
    |> Map.put("machines", indexed_map(rows))
    |> Map.put("machine_count", Integer.to_string(length(rows)))
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

  defp assign_live_projection(socket) do
    runtime_status = socket.assigns[:runtime_status] || TopologyCell.default_runtime_status()

    topology_id =
      runtime_status[:selected_running?] && runtime_status[:active] &&
        runtime_status.active.topology_id

    live_machine_instances = live_machine_instances(topology_id, socket.assigns[:topology_model])

    selected_live_machine =
      select_live_machine(live_machine_instances, socket.assigns[:selected_live_machine_id])

    socket
    |> assign(:live_machine_instances, live_machine_instances)
    |> assign(
      :selected_live_machine_id,
      selected_live_machine && to_string(selected_live_machine.machine_id)
    )
    |> assign(:selected_live_machine, selected_live_machine)
    |> assign(:selected_live_machine_diagram, live_machine_diagram(selected_live_machine))
    |> assign(:selected_live_skills, live_machine_skills(selected_live_machine))
  end

  defp live_machine_instances(nil, _topology_model), do: []

  defp live_machine_instances(topology_id, topology_model) when is_atom(topology_id) do
    snapshots =
      SnapshotStore.list_machines()
      |> Enum.filter(&(Map.get(&1.meta, :topology_id) == topology_id and &1.module))
      |> Map.new(fn snapshot -> {to_string(snapshot.machine_id), snapshot} end)

    modeled_instances = modeled_live_machine_instances(topology_id, topology_model)

    merged_instances =
      modeled_instances
      |> Enum.map(fn instance ->
        merge_live_machine_instance(instance, Map.get(snapshots, to_string(instance.machine_id)))
      end)

    extra_instances =
      snapshots
      |> Map.drop(Enum.map(modeled_instances, &to_string(&1.machine_id)))
      |> Map.values()

    (merged_instances ++ extra_instances)
    |> Enum.sort_by(&to_string(&1.machine_id))
  end

  defp modeled_live_machine_instances(_topology_id, %{machines: machines})
       when is_list(machines) do
    Enum.map(machines, fn machine ->
      %{
        machine_id: machine.name,
        module: live_machine_module(machine.module_name),
        current_state: nil,
        health: nil,
        last_signal: nil,
        last_transition_at: nil,
        restart_count: 0,
        connected?: false,
        facts: %{},
        fields: %{},
        outputs: %{},
        alarms: [],
        faults: [],
        dependencies: [],
        adapter_status: %{},
        meta: %{}
      }
    end)
  end

  defp modeled_live_machine_instances(_topology_id, _topology_model), do: []

  defp merge_live_machine_instance(instance, nil), do: instance

  defp merge_live_machine_instance(instance, snapshot) do
    snapshot_map =
      if is_struct(snapshot) do
        Map.from_struct(snapshot)
      else
        snapshot
      end

    Map.merge(instance, snapshot_map)
  end

  defp live_machine_module(module_name) when is_binary(module_name) do
    TopologySource.module_from_name!(module_name)
  rescue
    _error -> nil
  end

  defp live_machine_module(_module_name), do: nil

  defp select_live_machine([], _selected_machine_id), do: nil

  defp select_live_machine(live_machine_instances, selected_machine_id)
       when is_binary(selected_machine_id) do
    Enum.find(live_machine_instances, &(to_string(&1.machine_id) == selected_machine_id)) ||
      List.first(live_machine_instances)
  end

  defp select_live_machine(live_machine_instances, _selected_machine_id),
    do: List.first(live_machine_instances)

  defp live_machine_skills(nil), do: []

  defp live_machine_skills(%{module: module}) when is_atom(module) do
    if function_exported?(module, :skills, 0), do: module.skills(), else: []
  end

  defp live_machine_skills(_machine), do: []

  defp live_machine_diagram(nil), do: nil

  defp live_machine_diagram(machine) do
    case live_machine_graph_model(machine) do
      nil ->
        nil

      graph_model ->
        MachineGraph.mermaid(graph_model, active_state: machine.current_state)
    end
  end

  defp live_machine_graph_model(%{module: module}) when is_atom(module) do
    case machine_draft_for_module(module) do
      %{source: source} ->
        case MachineSource.graph_model_from_source(source) do
          {:ok, graph_model} -> graph_model
          {:error, _diagnostics} -> compiled_machine_graph_model(module)
        end

      _other ->
        compiled_machine_graph_model(module)
    end
  end

  defp live_machine_graph_model(_machine), do: nil

  defp machine_draft_for_module(module) when is_atom(module) do
    module_name = Atom.to_string(module) |> String.trim_leading("Elixir.")

    WorkspaceStore.list_machines()
    |> Enum.find(&machine_draft_matches_module?(&1, module_name))
  end

  defp machine_draft_matches_module?(%{model: %{module_name: module_name}}, expected_module_name)
       when is_binary(module_name) do
    module_name == expected_module_name
  end

  defp machine_draft_matches_module?(%{source: source}, expected_module_name)
       when is_binary(source) do
    case MachineSource.module_from_source(source) do
      {:ok, module} ->
        Atom.to_string(module) |> String.trim_leading("Elixir.") == expected_module_name

      {:error, :module_not_found} ->
        false
    end
  end

  defp machine_draft_matches_module?(_draft, _expected_module_name), do: false

  defp compiled_machine_graph_model(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__ogol_machine__, 0) do
      machine = module.__ogol_machine__()

      %{
        machine_id: machine.name |> to_string(),
        module_name: module |> Atom.to_string() |> String.trim_leading("Elixir."),
        meaning: machine.meaning,
        states:
          machine.states
          |> Map.values()
          |> Enum.sort_by(fn state ->
            {state.name != machine.initial_state, to_string(state.name)}
          end)
          |> Enum.map(fn state ->
            %{
              name: to_string(state.name),
              initial?: state.name == machine.initial_state or state.initial?,
              status: state.status,
              meaning: state.meaning
            }
          end),
        transitions:
          machine.transitions_by_source
          |> Map.values()
          |> List.flatten()
          |> Enum.map(fn transition ->
            {family, trigger_name} = normalize_live_trigger(transition.trigger)

            %{
              source: to_string(transition.source),
              family: Atom.to_string(family),
              trigger: to_string(trigger_name),
              destination: to_string(transition.destination),
              meaning: transition.meaning
            }
          end)
      }
    end
  end

  defp compiled_machine_graph_model(_module), do: nil

  defp normalize_live_trigger({family, name})
       when family in [:event, :request, :hardware, :state_timeout] and is_atom(name),
       do: {family, name}

  defp normalize_live_trigger(name) when is_atom(name), do: {:event, name}
  defp normalize_live_trigger(_other), do: {:event, :unknown}

  defp current_runtime_status(topology_id, source, model) do
    topology_status = TopologyRuntime.status(source, model)

    module_status =
      case Runtime.status(:topology, topology_id) do
        {:ok, status} ->
          status

        {:error, :not_found} ->
          %{source_digest: nil, blocked_reason: nil, lingering_pids: [], diagnostics: []}
      end

    Map.merge(topology_status, %{
      source_digest: module_status.source_digest,
      blocked_reason: module_status.blocked_reason,
      lingering_pids: module_status.lingering_pids,
      diagnostics: Map.get(module_status, :diagnostics, [])
    })
  end

  defp current_topology_cell(assigns) do
    assigns
    |> TopologyCell.facts_from_assigns()
    |> then(&StudioCellModel.derive(TopologyCell, &1))
  end

  defp current_topology_action(assigns, transition) do
    assigns
    |> current_topology_cell()
    |> StudioCellModel.action_for_transition(transition)
  end

  defp assign_topology_runtime_status(socket) do
    assign(
      socket,
      :runtime_status,
      current_runtime_status(
        socket.assigns.topology_id,
        socket.assigns.draft_source,
        socket.assigns.topology_model
      )
    )
  end

  defp guard_compiled_topology(socket, title) when is_binary(title) do
    if socket.assigns.current_source_digest != socket.assigns.runtime_status.source_digest do
      {:error,
       assign(
         socket,
         :studio_feedback,
         feedback(
           :warning,
           title,
           "Compile the current topology source before starting it."
         )
       )}
    else
      :ok
    end
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

  defp resolve_live_machine(live_machine_instances, machine_id) when is_binary(machine_id) do
    case Enum.find(live_machine_instances, &(to_string(&1.machine_id) == machine_id)) do
      nil -> {:error, {:machine_unavailable, machine_id}}
      machine -> {:ok, machine}
    end
  end

  defp resolve_live_skill(nil, skill_name), do: {:error, {:machine_unavailable, skill_name}}

  defp resolve_live_skill(machine, skill_name) when is_binary(skill_name) do
    case Enum.find(live_machine_skills(machine), &(to_string(&1.name) == skill_name)) do
      nil -> {:error, {:unknown_skill, skill_name}}
      skill -> {:ok, skill}
    end
  end

  defp dispatch_live_skill_async(owner, ref, machine_id, skill_name, payload) do
    Task.start(fn ->
      feedback =
        case CommandGateway.invoke(machine_id, skill_name, payload) do
          {:ok, reply} -> live_operator_feedback(:ok, machine_id, skill_name, reply)
          {:error, reason} -> live_operator_feedback(:error, machine_id, skill_name, reason)
        end

      send(owner, {:operator_control_result, ref, feedback})
    end)
  end

  defp live_operator_feedback(status, machine_id, skill_name, detail) do
    %{status: status, machine_id: machine_id, name: skill_name, detail: detail}
  end

  defp live_operator_feedback_summary(feedback) do
    "#{feedback.machine_id} :: skill #{feedback.name}"
  end

  defp live_operator_feedback_detail(%{status: :pending}), do: "invoking skill"

  defp live_operator_feedback_detail(%{status: :ok, detail: detail}),
    do: "reply=#{inspect(detail)}"

  defp live_operator_feedback_detail(%{status: :error, detail: detail}),
    do: "reason=#{inspect(detail)}"

  defp live_operator_feedback_classes(:ok), do: "border-emerald-400/30 bg-emerald-400/10"
  defp live_operator_feedback_classes(:pending), do: "border-cyan-400/30 bg-cyan-400/10"
  defp live_operator_feedback_classes(:error), do: "border-rose-400/30 bg-rose-400/10"

  defp live_state_label(nil), do: "Unknown"
  defp live_state_label(%{current_state: nil}), do: "Unknown"
  defp live_state_label(%{current_state: current_state}), do: to_string(current_state)

  defp live_health_label(nil), do: "Unknown"
  defp live_health_label(%{health: nil}), do: "Unknown"
  defp live_health_label(%{health: health}), do: to_string(health)

  defp sorted_entries(values) when is_map(values) do
    values
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {to_string(key), inspect(value)} end)
  end

  defp sorted_entries(_values), do: []

  defp format_optional(nil, fallback), do: fallback
  defp format_optional(value, _fallback), do: inspect(value)

  defp skill_input_type(:integer), do: "number"
  defp skill_input_type(:float), do: "number"
  defp skill_input_type(_type), do: "text"

  defp skill_input_step(:float), do: "any"
  defp skill_input_step(_type), do: nil

  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"

  defp present_text?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_text?(_value), do: false

  attr(:visual_form, :map, required: true)
  attr(:machine_module_options, :list, required: true)
  attr(:strategies, :list, required: true)
  attr(:restart_policies, :list, required: true)
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

      </section>

      <.machines_section
        rows={@visual_form["machines"]}
        machine_module_options={@machine_module_options}
        restart_policies={@restart_policies}
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

  attr(:runtime_status, :map, required: true)
  attr(:live_machine_instances, :list, required: true)
  attr(:selected_live_machine, :map, default: nil)
  attr(:selected_live_machine_diagram, :string, default: nil)
  attr(:selected_live_machine_id, :string, default: nil)
  attr(:selected_live_skills, :list, required: true)
  attr(:live_operator_feedback, :map, default: nil)

  defp live_editor(assigns) do
    ~H"""
    <section class="space-y-5">
      <div class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
        <p class="app-kicker">Live Runtime</p>
        <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
          Running machine instances
        </h3>
        <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
          Topology live mode scopes operator controls to the active topology. Each tab below targets one running machine instance.
        </p>

        <div :if={not @runtime_status.selected_running?} class="mt-4 rounded-xl border border-dashed border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-6 text-sm text-[var(--app-text-muted)]">
          Start the selected topology to inspect live machine instances here.
        </div>

        <div :if={@runtime_status.selected_running? and @live_machine_instances == []} class="mt-4 rounded-xl border border-dashed border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-6 text-sm text-[var(--app-text-muted)]">
          The active topology is running, but no machine projections are available yet.
        </div>

        <div :if={@live_machine_instances != []} class="mt-4 flex flex-wrap gap-2">
          <button
            :for={machine <- @live_machine_instances}
            type="button"
            phx-click="select_live_machine"
            phx-value-machine={machine.machine_id}
            class={[
              "rounded-full border px-3 py-2 text-sm font-medium transition",
              if(to_string(machine.machine_id) == @selected_live_machine_id,
                do: "border-[var(--app-accent)] bg-[var(--app-accent)]/15 text-[var(--app-text)]",
                else: "border-[var(--app-border)] bg-[var(--app-surface)] text-[var(--app-text-muted)] hover:text-[var(--app-text)]"
              )
            ]}
            data-test={"topology-live-machine-#{machine.machine_id}"}
          >
            {machine.machine_id}
          </button>
        </div>
      </div>

      <section
        :if={@selected_live_machine}
        class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4"
      >
        <div :if={@selected_live_machine_diagram} class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] p-3">
          <div
            id={"topology-live-machine-mermaid-#{@selected_live_machine.machine_id}"}
            phx-hook="MermaidDiagram"
            phx-update="ignore"
            data-diagram={@selected_live_machine_diagram}
            class="machine-mermaid min-h-[16rem]"
          >
          </div>
        </div>

        <div
          :if={is_nil(@selected_live_machine_diagram)}
          class="rounded-xl border border-dashed border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-6 text-sm text-[var(--app-text-muted)]"
        >
          Parse the selected machine into the supported model to render the live state diagram here.
        </div>
      </section>

      <div :if={@selected_live_machine} class="grid gap-5 2xl:grid-cols-[minmax(0,1.05fr)_minmax(22rem,0.95fr)]">
        <div class="space-y-4">
          <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p class="app-kicker">Instance</p>
                <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
                  {humanize_id(to_string(@selected_live_machine.machine_id))}
                </h3>
                <p class="mt-2 font-mono text-xs text-[var(--app-text-dim)]">
                  {inspect(@selected_live_machine.module)}
                </p>
              </div>

              <div class="grid gap-3 sm:grid-cols-3">
                <.metric_card label="State" value={live_state_label(@selected_live_machine)} />
                <.metric_card label="Health" value={live_health_label(@selected_live_machine)} />
                <.metric_card label="Connected" value={yes_no(@selected_live_machine.connected?)} />
              </div>
            </div>
          </section>

          <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
            <p class="app-kicker">Projected Status</p>
            <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
              Public machine values
            </h3>

            <div class="mt-4 grid gap-4 xl:grid-cols-3">
              <.live_data_panel
                title="Facts"
                entries={sorted_entries(@selected_live_machine.facts)}
                empty_label="No projected facts"
              />
              <.live_data_panel
                title="Fields"
                entries={sorted_entries(@selected_live_machine.fields)}
                empty_label="No projected fields"
              />
              <.live_data_panel
                title="Outputs"
                entries={sorted_entries(@selected_live_machine.outputs)}
                empty_label="No projected outputs"
              />
            </div>
          </section>
        </div>

        <aside class="space-y-4">
          <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
            <p class="app-kicker">Skills</p>
            <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
              Invoke public machine contract
            </h3>

            <div
              :if={@live_operator_feedback}
              class={[
                "mt-4 rounded-xl border px-3 py-3",
                live_operator_feedback_classes(@live_operator_feedback.status)
              ]}
            >
              <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
                Runtime Call
              </p>
              <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">
                {live_operator_feedback_summary(@live_operator_feedback)}
              </p>
              <p class="mt-2 font-mono text-[11px] text-[var(--app-text-muted)]">
                {live_operator_feedback_detail(@live_operator_feedback)}
              </p>
            </div>

            <div :if={@selected_live_skills == []} class="mt-4 rounded-xl border border-dashed border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-6 text-sm text-[var(--app-text-muted)]">
              No public skills are available for this machine instance.
            </div>

            <div :if={@selected_live_skills != []} class="mt-4 space-y-3">
              <form
                :for={skill <- @selected_live_skills}
                phx-submit="invoke_live_skill"
                class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4"
              >
                <input type="hidden" name="machine" value={@selected_live_machine.machine_id} />
                <input type="hidden" name="skill" value={skill.name} />

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
                    disabled={!@selected_live_machine.connected?}
                    title={if(!@selected_live_machine.connected?, do: "Machine instance is not currently connected.")}
                    data-test={"topology-live-skill-#{@selected_live_machine.machine_id}-#{skill.name}"}
                  >
                    Invoke
                  </button>
                </div>

                <div :if={MachineSkillForm.fields(skill) != []} class="mt-4 grid gap-3 sm:grid-cols-2">
                  <.skill_input_field
                    :for={field <- MachineSkillForm.fields(skill)}
                    field={field}
                  />
                </div>
              </form>
            </div>
          </section>

          <section class="rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-4">
            <p class="app-kicker">Runtime Posture</p>
            <h3 class="mt-2 text-lg font-semibold tracking-tight text-[var(--app-text)]">
              Signals and restart posture
            </h3>

            <div class="mt-4 grid gap-3 sm:grid-cols-2">
              <.metric_card
                label="Last Signal"
                value={format_optional(@selected_live_machine.last_signal, "none")}
              />
              <.metric_card
                label="Last Transition"
                value={format_optional(@selected_live_machine.last_transition_at, "unknown")}
              />
              <.metric_card
                label="Restarts"
                value={Integer.to_string(@selected_live_machine.restart_count || 0)}
              />
              <.metric_card
                label="Faults"
                value={Integer.to_string(length(@selected_live_machine.faults || []))}
              />
            </div>
          </section>
        </aside>
      </div>
    </section>
    """
  end

  attr(:title, :string, required: true)
  attr(:entries, :list, required: true)
  attr(:empty_label, :string, required: true)

  defp live_data_panel(assigns) do
    ~H"""
    <section class="rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-4 py-4">
      <div class="flex items-center justify-between gap-3">
        <p class="app-field-label">{@title}</p>
        <span class="rounded-full border border-[var(--app-border)] px-2 py-0.5 font-mono text-[10px] uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
          {length(@entries)}
        </span>
      </div>

      <div :if={@entries == []} class="mt-3 text-sm text-[var(--app-text-muted)]">
        {@empty_label}
      </div>

      <div :if={@entries != []} class="mt-3 space-y-2">
        <div :for={{key, value} <- @entries} class="flex items-start justify-between gap-3 text-sm">
          <span class="truncate font-mono uppercase tracking-[0.18em] text-[var(--app-text-dim)]">
            {key}
          </span>
          <span class="max-w-[16rem] text-right text-[var(--app-text)]">{value}</span>
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
      <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-dim)]">
        {@label}
      </p>
      <p class="mt-1 text-sm font-semibold text-[var(--app-text)]">{@value}</p>
    </div>
    """
  end

  attr(:field, :map, required: true)

  defp skill_input_field(assigns) do
    ~H"""
    <label :if={match?({:enum, _}, @field.type)} class="space-y-2">
      <span class="app-field-label">{@field.label}</span>
      <select name={"args[#{@field.name}]"} class="app-select w-full">
        <option
          :for={option <- elem(@field.type, 1)}
          value={option}
          selected={to_string(@field.value) == option}
        >
          {option}
        </option>
      </select>
      <span :if={present_text?(@field.summary)} class="block text-xs text-[var(--app-text-muted)]">
        {@field.summary}
      </span>
    </label>

    <label :if={@field.type == :boolean} class="space-y-2">
      <span class="app-field-label">{@field.label}</span>
      <span class="flex items-center gap-2 rounded-xl border border-[var(--app-border)] bg-[var(--app-surface)] px-3 py-3 text-sm text-[var(--app-text)]">
        <input type="hidden" name={"args[#{@field.name}]"} value="false" />
        <input
          type="checkbox"
          name={"args[#{@field.name}]"}
          value="true"
          checked={@field.value == true}
          class="size-4 rounded border-[var(--app-border)]"
        />
        Enabled
      </span>
      <span :if={present_text?(@field.summary)} class="block text-xs text-[var(--app-text-muted)]">
        {@field.summary}
      </span>
    </label>

    <label :if={@field.type in [:string, :integer, :float]} class="space-y-2">
      <span class="app-field-label">{@field.label}</span>
      <input
        type={skill_input_type(@field.type)}
        step={skill_input_step(@field.type)}
        name={"args[#{@field.name}]"}
        value={@field.value}
        class="app-input w-full"
      />
      <span :if={present_text?(@field.summary)} class="block text-xs text-[var(--app-text-muted)]">
        {@field.summary}
      </span>
    </label>
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
