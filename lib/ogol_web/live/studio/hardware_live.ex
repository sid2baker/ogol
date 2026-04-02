defmodule OgolWeb.Studio.HardwareLive do
  use OgolWeb, :live_view

  alias Ogol.Hardware.Config, as: HardwareConfig
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias OgolWeb.Live.SessionSync
  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Components.StatusBadge
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias Ogol.Studio.Cell, as: StudioCellModel
  alias Ogol.Hardware.Config.Studio.Cell, as: HardwareConfigCell
  alias Ogol.Session

  @event_limit 18
  @refresh_interval_ms 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Session.subscribe(:events)
      schedule_hardware_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Hardware Studio")
     |> assign(
       :page_summary,
       "Edit one hardware config, then derive simulator and EtherCAT master runtime behavior from it inside one hardware shell."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :hardware)
     |> assign(:hmi_subnav, :ethercat)
     |> assign(:event_limit, @event_limit)
     |> assign(:hardware_feedback, nil)
     |> assign(:hardware_feedback_ref, nil)
     |> assign(:mode_override, nil)
     |> assign(:requested_config_view, :visual)
     |> assign(:available_ethercat_drivers, available_ethercat_drivers())
     |> assign(:available_raw_interfaces, [])
     |> assign(:selected_support_snapshot_id, nil)
     |> assign(:capture_config_form, default_capture_config_form())
     |> assign(:events, Session.recent_events(@event_limit))
     |> StudioRevision.subscribe()
     |> maybe_load_hardware_state()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    previous_revision = socket.assigns[:studio_selected_revision]
    socket = StudioRevision.apply_param(socket, params)
    mode_override = mode_override_from_params(params)
    socket = maybe_reset_revision_simulation_form(socket, previous_revision)

    {:noreply,
     socket
     |> assign(:mode_override, mode_override)
     |> maybe_load_hardware_state()
     |> maybe_assign_revision_target_feedback()}
  end

  @impl true
  def handle_info({:event_logged, _notification}, socket) do
    {:noreply,
     socket
     |> assign(:events, Session.recent_events(@event_limit))
     |> maybe_load_hardware_state()}
  end

  def handle_info({:operations, operations}, socket) do
    previous_revision = socket.assigns[:studio_selected_revision]

    {:noreply,
     socket
     |> StudioRevision.apply_operations(operations)
     |> maybe_reset_revision_simulation_form(previous_revision)
     |> maybe_load_hardware_state()}
  end

  def handle_info({:runtime_updated, _action, _reply}, socket) do
    previous_revision = socket.assigns[:studio_selected_revision]

    {:noreply,
     socket
     |> maybe_reset_revision_simulation_form(previous_revision)
     |> maybe_load_hardware_state()}
  end

  def handle_info(:refresh_hardware, socket) do
    schedule_hardware_refresh()

    {:noreply, maybe_load_hardware_state(socket)}
  end

  def handle_info({:hardware_action_result, ref, feedback}, socket) do
    if socket.assigns.hardware_feedback_ref == ref do
      simulation_form =
        case feedback do
          %{config: config} ->
            maybe_persist_workspace_hardware_config(socket, config)
            socket = SessionSync.refresh(socket)

            if workspace_hardware_config_roundtrip_safe?(socket) do
              config_form_from_config(config)
            else
              socket.assigns.simulation_config_form
            end

          _other ->
            socket.assigns.simulation_config_form
        end

      {:noreply,
       socket
       |> assign(:hardware_feedback_ref, nil)
       |> assign(:hardware_feedback, feedback)
       |> assign(:simulation_config_form, simulation_form)
       |> maybe_load_hardware_state()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_hardware_mode", %{"mode" => raw_mode}, socket) do
    mode = parse_hardware_mode(raw_mode)

    next_mode =
      case mode do
        :armed when socket.assigns.hardware_context.pre_arm.status != :blocked -> :armed
        _other -> :testing
      end

    {:noreply,
     push_patch(
       socket,
       to: hardware_mode_path(next_mode, socket.assigns.studio_selected_revision)
     )}
  end

  def handle_event("select_config_view", %{"view" => raw_view}, socket) do
    {:noreply, assign(socket, :requested_config_view, parse_config_view(raw_view))}
  end

  @impl true
  def handle_event("change_slave_config", %{"slave_config" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_hardware(socket)}
    else
      slave_key = Map.get(params, "slave")

      {:noreply,
       update(socket, :slave_forms, fn forms ->
         Map.put(forms, slave_key, params)
       end)}
    end
  end

  def handle_event("change_simulation_config", %{"simulation_config" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_hardware(socket)}
    else
      merged_form =
        merge_simulation_config_form(socket.assigns.simulation_config_form, params)

      {:noreply,
       socket
       |> assign(:simulation_config_form, merged_form)
       |> maybe_persist_simulation_form(merged_form)
       |> maybe_load_hardware_state()}
    end
  end

  def handle_event("scan_master", _params, socket) do
    case Session.scan_ethercat_master_form(socket.assigns.simulation_config_form) do
      {:ok, scanned_form} ->
        {:noreply,
         socket
         |> assign(:hardware_feedback_ref, nil)
         |> assign(:hardware_feedback, master_scan_feedback(:ok, scanned_form))
         |> assign(:simulation_config_form, scanned_form)
         |> maybe_persist_simulation_form(scanned_form)
         |> maybe_load_hardware_state()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:hardware_feedback_ref, nil)
         |> assign(:hardware_feedback, master_scan_feedback(:error, reason))}
    end
  end

  def handle_event("start_master", _params, socket) do
    config_input = master_runtime_input(socket)

    case Session.start_ethercat_master(config_input) do
      {:ok, runtime} ->
        {:noreply,
         socket
         |> assign(:hardware_feedback_ref, nil)
         |> assign(:hardware_feedback, master_feedback(:ok, :start, runtime))
         |> maybe_load_hardware_state()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:hardware_feedback_ref, nil)
         |> assign(:hardware_feedback, master_feedback(:error, :start, reason))}
    end
  end

  def handle_event("stop_master", _params, socket) do
    case Session.stop_ethercat_master() do
      :ok ->
        {:noreply,
         socket
         |> assign(:hardware_feedback_ref, nil)
         |> assign(:hardware_feedback, master_feedback(:ok, :stop, nil))
         |> maybe_load_hardware_state()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:hardware_feedback_ref, nil)
         |> assign(:hardware_feedback, master_feedback(:error, :stop, reason))}
    end
  end

  def handle_event("change_capture_config", %{"capture_config" => params}, socket) do
    if StudioRevision.read_only?(socket) do
      {:noreply, readonly_hardware(socket)}
    else
      {:noreply, assign(socket, :capture_config_form, normalize_capture_config_form(params))}
    end
  end

  def handle_event("add_simulation_domain", _params, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      simulation_allowed?(socket.assigns.hardware_context) ->
        {:noreply,
         socket
         |> update(:simulation_config_form, fn form ->
           form
           |> normalize_simulation_config_form()
           |> update_in(["domains"], fn domains -> domains ++ [empty_simulation_domain_row()] end)
         end)
         |> persist_current_simulation_form()
         |> maybe_load_hardware_state()}

      true ->
        {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("remove_simulation_domain", %{"index" => index}, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      simulation_allowed?(socket.assigns.hardware_context) ->
        {:noreply,
         socket
         |> update(:simulation_config_form, fn form ->
           form
           |> normalize_simulation_config_form()
           |> update_in(["domains"], fn domains -> remove_simulation_domain(domains, index) end)
         end)
         |> persist_current_simulation_form()
         |> maybe_load_hardware_state()}

      true ->
        {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("add_simulation_slave", _params, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      simulation_allowed?(socket.assigns.hardware_context) ->
        {:noreply,
         socket
         |> update(:simulation_config_form, fn form ->
           form
           |> normalize_simulation_config_form()
           |> update_in(["slaves"], fn slaves -> slaves ++ [empty_simulation_slave_row()] end)
         end)
         |> persist_current_simulation_form()
         |> maybe_load_hardware_state()}

      true ->
        {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("remove_simulation_slave", %{"index" => index}, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      simulation_allowed?(socket.assigns.hardware_context) ->
        {:noreply,
         socket
         |> update(:simulation_config_form, fn form ->
           form
           |> normalize_simulation_config_form()
           |> update_in(["slaves"], fn slaves -> remove_simulation_slave(slaves, index) end)
         end)
         |> persist_current_simulation_form()
         |> maybe_load_hardware_state()}

      true ->
        {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("start_simulation", _params, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      config_input = simulation_runtime_input(socket)
      config_id = simulation_runtime_input_id(config_input, "draft")

      case Session.start_simulation_config(config_input) do
        {:ok, %{config: config} = runtime} ->
          {:noreply,
           socket
           |> assign(:hardware_feedback_ref, nil)
           |> assign(
             :hardware_feedback,
             simulation_feedback(:ok, config.id, Map.delete(runtime, :config), config)
           )
           |> assign(:simulation_config_form, config_form_from_config(config))
           |> maybe_load_hardware_state()}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:hardware_feedback_ref, nil)
           |> assign(:hardware_feedback, simulation_feedback(:error, config_id, reason))}
      end
    else
      {:noreply, deny_hardware_action(socket, :start_simulation)}
    end
  end

  def handle_event("stop_simulation", _params, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      case current_simulation_config_id(
             socket.assigns.hardware_context,
             running_simulation_config_id(socket.assigns.events, socket.assigns.hardware_context),
             socket.assigns.simulation_config_form
           ) do
        nil ->
          {:noreply,
           socket
           |> assign(:hardware_feedback_ref, nil)
           |> assign(
             :hardware_feedback,
             invalid_feedback(:stop_simulation, :missing_simulation_config)
           )}

        config_id ->
          case Session.stop_simulation(config_id) do
            :ok ->
              {:noreply,
               socket
               |> assign(:hardware_feedback_ref, nil)
               |> assign(:hardware_feedback, simulation_stop_feedback(:ok, config_id))
               |> maybe_load_hardware_state()}

            {:error, reason} ->
              {:noreply,
               socket
               |> assign(:hardware_feedback_ref, nil)
               |> assign(:hardware_feedback, simulation_stop_feedback(:error, config_id, reason))}
          end
      end
    else
      {:noreply, deny_hardware_action(socket, :stop_simulation)}
    end
  end

  def handle_event("capture_live_hardware", %{"capture_config" => params}, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      capture_allowed?(socket.assigns.hardware_context) ->
        ref = make_ref()
        capture_params = normalize_capture_config_form(params)

        dispatch_hardware_action_async(self(), ref, fn ->
          case Session.capture_ethercat_hardware_config(capture_params) do
            {:ok, config} -> {:ok, capture_feedback(:ok, config)}
            {:error, reason} -> {:error, capture_feedback(:error, reason)}
          end
        end)

        {:noreply,
         socket
         |> assign(:capture_config_form, capture_params)
         |> assign(:hardware_feedback_ref, ref)
         |> assign(:hardware_feedback, capture_feedback(:pending, nil))}

      true ->
        {:noreply, deny_hardware_action(socket, :capture_live_hardware)}
    end
  end

  def handle_event("capture_runtime_snapshot", _params, socket) do
    {:noreply, capture_support_snapshot(socket, :runtime)}
  end

  def handle_event("capture_support_snapshot", _params, socket) do
    {:noreply, capture_support_snapshot(socket, :support)}
  end

  def handle_event("promote_draft_candidate", _params, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      candidate_promotion_allowed?(socket.assigns.hardware_context) ->
        case Session.preview_ethercat_simulation_config(socket.assigns.simulation_config_form) do
          {:ok, config} ->
            {:ok, candidate} = Session.promote_candidate_config(config)

            {:noreply,
             socket
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, candidate_feedback(:ok, candidate))
             |> maybe_load_hardware_state()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, candidate_feedback(:error, reason))}
        end

      true ->
        {:noreply, deny_hardware_action(socket, :promote_draft_candidate)}
    end
  end

  def handle_event("arm_candidate_release", _params, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      candidate_arm_allowed?(
        socket.assigns.hardware_context,
        socket.assigns.current_candidate_release
      ) ->
        case Session.arm_candidate_release() do
          {:ok, release} ->
            {:noreply,
             socket
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, candidate_release_feedback(:ok, release))
             |> maybe_load_hardware_state()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, candidate_release_feedback(:error, reason))}
        end

      true ->
        {:noreply, deny_hardware_action(socket, :arm_candidate_release)}
    end
  end

  def handle_event("rollback_armed_release", %{"version" => version}, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      release_rollback_allowed?(
        socket.assigns.hardware_context,
        socket.assigns.current_armed_release
      ) ->
        case Session.rollback_armed_release(version) do
          {:ok, release} ->
            {:noreply,
             socket
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, rollback_feedback(:ok, release))
             |> maybe_load_hardware_state()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, rollback_feedback(:error, reason))}
        end

      true ->
        {:noreply, deny_hardware_action(socket, :rollback_armed_release)}
    end
  end

  def handle_event("select_support_snapshot", %{"snapshot_id" => snapshot_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_support_snapshot_id, snapshot_id)
     |> maybe_load_hardware_state()}
  end

  def handle_event("clone_live_to_draft", _params, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      capture_allowed?(socket.assigns.hardware_context) ->
        capture_params = normalize_capture_config_form(socket.assigns.capture_config_form)

        case Session.preview_ethercat_hardware_config(capture_params) do
          {:ok, config} ->
            {:noreply,
             socket
             |> assign(:capture_config_form, capture_params)
             |> assign(:simulation_config_form, config_form_from_config(config))
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, clone_feedback(:ok, config))
             |> maybe_load_hardware_state()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:capture_config_form, capture_params)
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, clone_feedback(:error, reason))}
        end

      true ->
        {:noreply, deny_hardware_action(socket, :clone_live_to_draft)}
    end
  end

  def handle_event("save_slave_config", %{"slave_config" => params}, socket) do
    cond do
      StudioRevision.read_only?(socket) ->
        {:noreply, readonly_hardware(socket)}

      provisioning_allowed?(socket.assigns.hardware_context) ->
        with {:ok, slave_name} <- parse_slave_name(Map.get(params, "slave")) do
          ref = make_ref()

          dispatch_hardware_action_async(self(), ref, fn ->
            case Session.configure_ethercat_slave(slave_name, params) do
              {:ok, spec} -> {:ok, configure_feedback(:ok, slave_name, spec)}
              {:error, reason} -> {:error, configure_feedback(:error, slave_name, reason)}
            end
          end)

          {:noreply,
           socket
           |> update(:slave_forms, &Map.put(&1, Map.get(params, "slave"), params))
           |> assign(:hardware_feedback_ref, ref)
           |> assign(:hardware_feedback, configure_feedback(:pending, slave_name, nil))}
        else
          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:hardware_feedback_ref, nil)
             |> assign(:hardware_feedback, invalid_feedback(:configure_slave, reason))}
        end

      true ->
        {:noreply, deny_hardware_action(socket, :configure_slave)}
    end
  end

  def handle_event("activate_ethercat", _params, socket) do
    if runtime_control_allowed?(socket.assigns.hardware_context) do
      ref = make_ref()

      dispatch_hardware_action_async(self(), ref, fn ->
        case Session.activate_ethercat() do
          :ok -> {:ok, session_feedback(:ok, :activate, nil)}
          {:error, reason} -> {:error, session_feedback(:error, :activate, reason)}
        end
      end)

      {:noreply,
       socket
       |> assign(:hardware_feedback_ref, ref)
       |> assign(:hardware_feedback, session_feedback(:pending, :activate, nil))}
    else
      {:noreply, deny_hardware_action(socket, :activate_ethercat)}
    end
  end

  def handle_event("deactivate_ethercat", %{"target" => target}, socket) do
    if runtime_control_allowed?(socket.assigns.hardware_context) do
      case parse_deactivate_target(target) do
        {:ok, state_target} ->
          ref = make_ref()

          dispatch_hardware_action_async(self(), ref, fn ->
            case Session.deactivate_ethercat(state_target) do
              :ok ->
                {:ok, session_feedback(:ok, :deactivate, state_target)}

              {:error, reason} ->
                {:error, session_feedback(:error, :deactivate, {state_target, reason})}
            end
          end)

          {:noreply,
           socket
           |> assign(:hardware_feedback_ref, ref)
           |> assign(:hardware_feedback, session_feedback(:pending, :deactivate, state_target))}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:hardware_feedback_ref, nil)
           |> assign(:hardware_feedback, invalid_feedback(:deactivate, reason))}
      end
    else
      {:noreply, deny_hardware_action(socket, :deactivate_ethercat)}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :hardware_config_cell,
        StudioCellModel.derive(HardwareConfigCell, HardwareConfigCell.facts_from_assigns(assigns))
      )

    ~H"""
    <div class="mx-auto max-w-none space-y-4">
      <.feedback_banner feedback={@hardware_feedback} />

      <.hardware_config_section
        ethercat={@ethercat}
        hardware_context={@hardware_context}
        simulation_config_form={@simulation_config_form}
        effective_simulation_config={@effective_simulation_config}
        hardware_config_cell={@hardware_config_cell}
        hardware_config_source={@hardware_config_source}
        available_ethercat_drivers={@available_ethercat_drivers}
        available_raw_interfaces={@available_raw_interfaces}
        studio_read_only?={@studio_read_only?}
      />

      <.simulator_runtime_section
        hardware_context={@hardware_context}
        simulation_config_form={@simulation_config_form}
      />

      <.master_runtime_section
        ethercat={@ethercat}
        hardware_context={@hardware_context}
      />

      <.transition_sections_keepalive
        hardware_context={@hardware_context}
        ethercat={@ethercat}
        capture_config_form={@capture_config_form}
        simulation_config_form={@simulation_config_form}
        live_preview={@live_hardware_preview}
        draft_live_diff={@draft_live_diff}
        slave_forms={@slave_forms}
        current_candidate_release={@current_candidate_release}
        current_armed_release={@current_armed_release}
        candidate_vs_armed_diff={@candidate_vs_armed_diff}
        release_history={@release_history}
        events={@events}
        support_snapshots={@support_snapshots}
        selected_support_snapshot={@selected_support_snapshot}
      />
    </div>
    """
  end

  attr(:hardware_context, :map, required: true)
  attr(:ethercat, :map, required: true)
  attr(:capture_config_form, :map, required: true)
  attr(:simulation_config_form, :map, required: true)
  attr(:live_preview, :any, required: true)
  attr(:draft_live_diff, :map, required: true)
  attr(:slave_forms, :map, required: true)
  attr(:current_candidate_release, :any, required: true)
  attr(:current_armed_release, :any, required: true)
  attr(:candidate_vs_armed_diff, :map, required: true)
  attr(:release_history, :list, required: true)
  attr(:events, :list, required: true)
  attr(:support_snapshots, :list, required: true)
  attr(:selected_support_snapshot, :any, required: true)

  # Keep the transition-era components compiled while the EtherCAT page is
  # narrowed to master/bus supervision. This prevents warning churn until the
  # remaining workflows move to their own Studio surfaces.
  defp transition_sections_keepalive(assigns) do
    ~H"""
    <div :if={false}>
      <.status_section ethercat={@ethercat} hardware_context={@hardware_context} />
      <.devices_section ethercat={@ethercat} />
      <.diagnostics_section
        events={@events}
        support_snapshots={@support_snapshots}
        selected_support_snapshot={@selected_support_snapshot}
      />
      <.commissioning_section hardware_context={@hardware_context} />
      <.capture_section
        ethercat={@ethercat}
        hardware_context={@hardware_context}
        capture_config_form={@capture_config_form}
        simulation_config_form={@simulation_config_form}
        live_preview={@live_preview}
        draft_live_diff={@draft_live_diff}
      />
      <.provisioning_section
        ethercat={@ethercat}
        slave_forms={@slave_forms}
        hardware_context={@hardware_context}
      />
      <.release_section
        hardware_context={@hardware_context}
        simulation_config_form={@simulation_config_form}
        current_candidate_release={@current_candidate_release}
        current_armed_release={@current_armed_release}
        candidate_vs_armed_diff={@candidate_vs_armed_diff}
        release_history={@release_history}
      />
    </div>
    """
  end

  attr(:hardware_context, :map, required: true)
  attr(:simulation_config_form, :map, required: true)
  attr(:current_candidate_release, :any, required: true)
  attr(:current_armed_release, :any, required: true)
  attr(:candidate_vs_armed_diff, :map, required: true)
  attr(:release_history, :list, required: true)

  defp release_section(assigns) do
    ~H"""
    <section class="overflow-hidden border border-fuchsia-400/18 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]" data-test="hardware-section-release">
      <div class="border-b border-fuchsia-400/12 px-4 py-4 sm:px-5">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-fuchsia-100/75">
              Candidate vs Armed
            </p>
            <h3 class="mt-1 text-lg font-semibold text-white">Release posture for hardware-facing work</h3>
            <p class="mt-1 text-sm text-slate-400">
              Promote the staged draft to a tested candidate, compare it with the current armed baseline, and only arm from explicit live posture.
            </p>
            <p :if={compact_release_section?(@hardware_context, @candidate_vs_armed_diff)} class="mt-2 text-[12px] text-fuchsia-100/75">
              Compact view while no live hardware is connected.
            </p>
          </div>

          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="promote_draft_candidate"
              data-test="promote-draft-candidate"
              disabled={!candidate_promotion_allowed?(@hardware_context)}
              class={session_button_classes(:configure, candidate_promotion_allowed?(@hardware_context))}
            >
              Promote Draft To Candidate
            </button>
            <button
              type="button"
              phx-click="arm_candidate_release"
              data-test="arm-candidate-release"
              data-confirm={candidate_arm_confirm(@current_candidate_release, @candidate_vs_armed_diff)}
              disabled={!candidate_arm_allowed?(@hardware_context, @current_candidate_release)}
              class={session_button_classes(:activate, candidate_arm_allowed?(@hardware_context, @current_candidate_release))}
            >
              Arm Candidate
            </button>
          </div>
        </div>
      </div>

      <div class="grid gap-px bg-white/8 sm:grid-cols-2 xl:grid-cols-4">
        <.summary_panel label="Draft" value={Map.get(@simulation_config_form, "id", "unsaved")} detail="current staged hardware draft" />
        <.summary_panel label="Candidate" value={candidate_label(@current_candidate_release)} detail="latest promoted candidate build" />
        <.summary_panel label="Armed Live" value={armed_release_label(@current_armed_release)} detail="current armed release baseline" />
        <.summary_panel label="Change Class" value={candidate_change_class(@candidate_vs_armed_diff)} detail="derived bump against the armed baseline" />
      </div>

      <div
        :if={compact_release_section?(@hardware_context, @candidate_vs_armed_diff)}
        class="grid gap-4 p-3 sm:grid-cols-2 sm:p-4 xl:grid-cols-4"
        data-test="hardware-section-release-compact"
      >
        <.detail_panel title="Comparison" body={@candidate_vs_armed_diff.summary} />
        <.detail_panel title="Promotion Gate" body={candidate_promotion_notice(@hardware_context)} />
        <.detail_panel title="Armed Baseline" body={armed_snapshot_label(@current_armed_release)} />
        <.detail_panel title="Release History" body={compact_release_history_label(@release_history)} />
      </div>

      <div
        :if={!compact_release_section?(@hardware_context, @candidate_vs_armed_diff)}
        class="grid gap-4 p-3 sm:p-4 xl:grid-cols-[minmax(0,0.95fr)_minmax(0,1.05fr)]"
      >
        <div class="space-y-2">
          <.detail_panel title="Candidate Config" body={candidate_config_label(@current_candidate_release)} />
          <.detail_panel title="Armed Config" body={armed_config_label(@current_armed_release)} />
          <.detail_panel
            title="Candidate Deployment"
            body={candidate_snapshot_label(@current_candidate_release)}
          />
          <.detail_panel
            title="Armed Deployment"
            body={armed_snapshot_label(@current_armed_release)}
          />
          <.detail_panel title="Comparison" body={@candidate_vs_armed_diff.summary} />
          <.detail_panel title="Promotion Gate" body={candidate_promotion_notice(@hardware_context)} />
          <.detail_panel title="Arm Gate" body={candidate_arm_notice(@hardware_context, @current_candidate_release)} />
          <.detail_panel title="Rollback Gate" body={release_rollback_notice(@hardware_context, @current_armed_release)} />
        </div>

        <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
          <.mismatch_panel title="Domain Diff" rows={mismatch_rows(@candidate_vs_armed_diff.hardware.domain_mismatches)} />
          <.mismatch_panel title="Slave Diff" rows={mismatch_rows(@candidate_vs_armed_diff.hardware.slave_mismatches)} />
          <.mismatch_panel
            title="Machine Diff"
            rows={mismatch_rows(@candidate_vs_armed_diff.machine_mismatches ++ @candidate_vs_armed_diff.candidate_only_machines ++ @candidate_vs_armed_diff.armed_only_machines)}
          />
          <.mismatch_panel
            title="Topology Diff"
            rows={mismatch_rows(@candidate_vs_armed_diff.topology_mismatches ++ @candidate_vs_armed_diff.candidate_only_topologies ++ @candidate_vs_armed_diff.armed_only_topologies)}
          />
          <.mismatch_panel
            title="Panel Diff"
            rows={mismatch_rows(@candidate_vs_armed_diff.panel_mismatches ++ @candidate_vs_armed_diff.candidate_only_panels ++ @candidate_vs_armed_diff.armed_only_panels)}
          />
        </div>
      </div>

      <div :if={!compact_release_section?(@hardware_context, @candidate_vs_armed_diff)} class="border-t border-white/10 p-3 sm:p-4">
        <div class="flex items-start justify-between gap-3">
          <div>
            <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-fuchsia-100/75">
              Release History
            </p>
            <p class="mt-1 text-sm text-slate-400">
              Earlier immutable releases remain available for explicit rollback.
            </p>
          </div>
          <StatusBadge.badge status={if(@release_history == [], do: :stale, else: :healthy)} />
        </div>

        <div class="mt-3 divide-y divide-white/8 border border-white/8 bg-slate-900/50">
          <div :if={@release_history == []} class="px-4 py-4 text-sm text-slate-400">
            No armed releases exist yet.
          </div>

          <div
            :for={release <- Enum.take(@release_history, 5)}
            class="flex flex-col gap-3 px-4 py-3 xl:flex-row xl:items-center xl:justify-between"
            data-test={"release-history-#{release.version}"}
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <p class="text-sm font-semibold text-slate-100">{release.version}</p>
                <StatusBadge.badge status={if(@current_armed_release && @current_armed_release.version == release.version, do: :healthy, else: :stale)} />
              </div>
              <p class="mt-1 font-mono text-[11px] text-slate-500">
                build={release.candidate_build_id} bump={release.bump} released_at={format_timestamp(release.released_at)}
              </p>
              <p class="mt-2 text-[12px] text-slate-300">
                {release.diff.summary}
              </p>
            </div>

            <button
              :if={@current_armed_release && @current_armed_release.version != release.version}
              type="button"
              phx-click="rollback_armed_release"
              phx-value-version={release.version}
              data-test={"rollback-release-#{release.version}"}
              data-confirm={rollback_confirm(release)}
              disabled={!release_rollback_allowed?(@hardware_context, @current_armed_release)}
              class={session_button_classes(:deactivate, release_rollback_allowed?(@hardware_context, @current_armed_release))}
            >
              Roll Back To {release.version}
            </button>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr(:ethercat, :map, required: true)
  attr(:hardware_context, :map, required: true)

  defp status_section(assigns) do
    ~H"""
    <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]" data-test="hardware-section-bus-watch">
      <div class="border-b border-white/10 px-4 py-4 sm:px-5">
        <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
          Bus Watch
        </p>
        <h3 class="mt-1 text-lg font-semibold text-white">Observed EtherCAT runtime</h3>
        <p class="mt-1 text-sm text-slate-400">
          Watch the public master state, bus health, and timing surface here. Runtime transitions are handled from the master cell so this section stays focused on observation.
        </p>
      </div>

      <div class="grid gap-px bg-white/8 sm:grid-cols-2 xl:grid-cols-4">
        <.summary_panel label="Summary State" value={@hardware_context.summary.label} detail="synthesized operator-facing state" />
        <.summary_panel label="Master State" value={format_result(@ethercat.state)} detail="public runtime state" />
        <.summary_panel label="Bus" value={format_result(@ethercat.bus)} detail="transport runtime" />
        <.summary_panel label="DC Lock" value={dc_lock_value(@ethercat.dc_status)} detail="distributed clocks" />
        <.summary_panel label="Domains" value={domain_count(@ethercat.domains)} detail="configured timing groups" />
        <.summary_panel label="Reference Clock" value={reference_clock_value(@ethercat.reference_clock)} detail="station clock source" />
        <.summary_panel label="Last Failure" value={failure_summary(@ethercat.last_failure)} detail="retained terminal fault" />
        <.summary_panel label="Tracked Endpoints" value={length(@ethercat.hardware_snapshots)} detail="Ogol-side observed endpoints" />
      </div>
    </section>
    """
  end

  attr(:hardware_context, :map, required: true)

  defp commissioning_section(assigns) do
    ~H"""
    <section class="overflow-hidden border border-amber-300/20 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]" data-test="hardware-section-commissioning">
      <div class="border-b border-amber-300/15 px-4 py-4 sm:px-5">
        <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
          Commissioning
        </p>
        <h3 class="mt-1 text-lg font-semibold text-white">Expected vs actual hardware</h3>
        <p class="mt-1 text-sm text-slate-400">
          This projection keeps expectation visible before deeper diagnostics. It is scoped to the active saved simulation config when one exists.
        </p>
      </div>

      <div class="grid gap-4 p-3 sm:p-4 xl:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)]">
        <div class="grid gap-2 sm:grid-cols-2">
          <.detail_panel title="Config Id" body={@hardware_context.commissioning.config_id || "none"} />
          <.detail_panel title="Topology Match" body={humanize_context(@hardware_context.observed.topology_match)} />
          <.detail_panel title="Expected Devices" body={join_list(@hardware_context.commissioning.expected_devices, "none")} />
          <.detail_panel title="Actual Devices" body={join_list(@hardware_context.commissioning.actual_devices, "none")} />
          <.detail_panel title="Missing" body={join_list(@hardware_context.commissioning.missing_devices, "none")} />
          <.detail_panel title="Extra" body={join_list(@hardware_context.commissioning.extra_devices, "none")} />
        </div>

        <div class="grid gap-3 md:grid-cols-3">
          <.mismatch_panel title="Identity Mismatch" rows={format_mismatch_rows(@hardware_context.commissioning.identity_mismatches)} />
          <.mismatch_panel title="State Mismatch" rows={format_mismatch_rows(@hardware_context.commissioning.state_mismatches)} />
          <.mismatch_panel title="Inhibited Outputs" rows={Enum.map(@hardware_context.commissioning.inhibited_outputs, &to_string/1)} />
        </div>
      </div>
    </section>
    """
  end

  attr(:ethercat, :map, required: true)
  attr(:hardware_context, :map, required: true)
  attr(:capture_config_form, :map, required: true)
  attr(:simulation_config_form, :map, required: true)
  attr(:live_preview, :any, required: true)
  attr(:draft_live_diff, :map, required: true)

  defp capture_section(assigns) do
    ~H"""
    <section class="overflow-hidden border border-cyan-400/20 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]" data-test="hardware-section-capture">
      <div class="border-b border-cyan-400/15 px-4 py-4 sm:px-5">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-cyan-100/75">
              Capture / Baseline
            </p>
            <h3 class="mt-1 text-lg font-semibold text-white">Use connected hardware as a config baseline</h3>
            <p class="mt-1 text-sm text-slate-400">
              Capture the currently connected EtherCAT ring as a reusable `hardware_config`. This produces a simulator-ready baseline from live topology, drivers, and detected process-data shape without editing the armed runtime in place.
            </p>
          </div>

          <div class="text-sm text-slate-400">
            Choose a reusable config id and label so the captured ring is ready for later simulator work.
          </div>
        </div>

        <div :if={action_notice(@hardware_context, :capture)} class="mt-3 border border-amber-300/20 bg-amber-300/8 px-3 py-2 text-[12px] text-amber-50">
          {action_notice(@hardware_context, :capture)}
        </div>
      </div>

      <div class="grid gap-px bg-white/8 sm:grid-cols-2 xl:grid-cols-4">
        <.summary_panel label="Detected Slaves" value={Integer.to_string(length(@ethercat.slaves))} detail="live topology size" />
        <.summary_panel label="Configured Domains" value={Integer.to_string(domain_count(@ethercat.domains))} detail="captured simulation timing groups" />
        <.summary_panel label="Mode" value={mode_label(@hardware_context)} detail="current live posture" />
        <.summary_panel label="Write Policy" value={humanize_context(@hardware_context.mode.write_policy)} detail="capture is allowed in testing and armed" />
      </div>

      <div class="grid gap-4 border-t border-white/10 p-3 sm:p-4 xl:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)]">
        <div class="space-y-3">
          <div class="flex items-start justify-between gap-3">
            <div>
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-cyan-100/75">
                Draft vs Live
              </p>
              <h4 class="mt-1 text-base font-semibold text-white">Compare the staged draft against connected hardware</h4>
            </div>
            <StatusBadge.badge status={draft_live_diff_badge(@draft_live_diff.status)} />
          </div>

          <p class="text-sm text-slate-300" data-test="draft-live-diff-summary">
            {@draft_live_diff.summary}
          </p>

          <div class="grid gap-2 sm:grid-cols-2">
            <.detail_panel
              title="Staged Draft"
              body={Map.get(@simulation_config_form, "id", "unsaved draft")}
            />
            <.detail_panel
              title="Live Preview"
              body={live_preview_label(@live_preview)}
            />
            <.detail_panel
              title="Draft-only Domains"
              body={join_list(@draft_live_diff.draft_only_domains, "none")}
            />
            <.detail_panel
              title="Live-only Domains"
              body={join_list(@draft_live_diff.live_only_domains, "none")}
            />
            <.detail_panel
              title="Draft-only Slaves"
              body={join_list(@draft_live_diff.draft_only_slaves, "none")}
            />
            <.detail_panel
              title="Live-only Slaves"
              body={join_list(@draft_live_diff.live_only_slaves, "none")}
            />
          </div>
        </div>

        <div class="grid gap-3 md:grid-cols-2">
          <.mismatch_panel title="Domain Mismatch" rows={mismatch_rows(@draft_live_diff.domain_mismatches)} />
          <.mismatch_panel title="Slave Mismatch" rows={mismatch_rows(@draft_live_diff.slave_mismatches)} />
        </div>
      </div>

      <form
        id="capture-config-form"
        phx-change="change_capture_config"
        phx-submit="capture_live_hardware"
        class="grid gap-3 border-t border-white/10 p-3 sm:grid-cols-[minmax(0,0.9fr)_minmax(0,1.1fr)_auto]"
        data-test="capture-config-form"
      >
        <label class="space-y-1.5">
          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Config Id</span>
          <input
            type="text"
            name="capture_config[id]"
            value={Map.get(@capture_config_form, "id", "")}
            class={input_classes()}
            placeholder="packaging_line"
          />
        </label>

        <label class="space-y-1.5">
          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Label</span>
          <input
            type="text"
            name="capture_config[label]"
            value={Map.get(@capture_config_form, "label", "")}
            class={input_classes()}
            placeholder="Packaging Line"
          />
        </label>

        <div class="flex flex-wrap items-end gap-2">
          <button
            type="button"
            phx-click="clone_live_to_draft"
            data-test="clone-live-to-draft"
            disabled={!capture_allowed?(@hardware_context)}
            class={session_button_classes(:deactivate, capture_allowed?(@hardware_context))}
          >
            Clone live to draft
          </button>
          <button
            type="submit"
            data-test="capture-live-hardware"
            disabled={!capture_allowed?(@hardware_context)}
            class={session_button_classes(:configure, capture_allowed?(@hardware_context))}
          >
            Capture live as config
          </button>
        </div>
      </form>
    </section>
    """
  end

  attr(:ethercat, :map, required: true)

  defp devices_section(assigns) do
    ~H"""
    <section class="grid gap-4 xl:grid-cols-[minmax(0,0.7fr)_minmax(0,1.3fr)]" data-test="hardware-section-devices">
      <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
        <div class="border-b border-white/10 px-4 py-4">
          <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
            Protocol Surface
          </p>
          <h3 class="mt-1 text-lg font-semibold text-white">Available hardware runtimes</h3>
        </div>

        <div class="divide-y divide-white/8">
          <div
            :for={protocol <- @ethercat.protocols}
            class="flex items-center justify-between gap-3 px-4 py-3"
          >
            <div>
              <p class="text-sm font-semibold text-slate-100">{protocol.label}</p>
              <p class="mt-1 font-mono text-[11px] text-slate-500">{protocol.id}</p>
            </div>
            <StatusBadge.badge status={protocol_status(protocol)} />
          </div>
        </div>
      </section>

      <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
        <div class="border-b border-white/10 px-4 py-4">
          <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
            Topology / Devices
          </p>
          <h3 class="mt-1 text-lg font-semibold text-white">Observed EtherCAT endpoints</h3>
        </div>

        <div class="divide-y divide-white/8">
          <div
            :if={@ethercat.hardware_snapshots == []}
            class="px-4 py-6 text-sm text-slate-400"
          >
            No Ogol-attached EtherCAT endpoints observed yet.
          </div>

          <article
            :for={snapshot <- @ethercat.hardware_snapshots}
            class="px-4 py-3"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="text-sm font-semibold text-slate-100">{snapshot.endpoint_id}</p>
                <p class="mt-1 font-mono text-[11px] text-slate-500">
                  feedback={format_timestamp(snapshot.last_feedback_at)}
                </p>
              </div>
              <StatusBadge.badge status={if(snapshot.connected?, do: :healthy, else: :disconnected)} />
            </div>

            <div class="mt-2 space-y-1 text-[11px] text-slate-300">
              <p>signals: {map_preview(snapshot.observed_signals)}</p>
              <p>outputs: {map_preview(snapshot.driven_outputs)}</p>
            </div>
          </article>
        </div>
      </section>
    </section>
    """
  end

  attr(:events, :list, required: true)
  attr(:support_snapshots, :list, required: true)
  attr(:selected_support_snapshot, :any, required: true)

  defp diagnostics_section(assigns) do
    ~H"""
    <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]" data-test="hardware-section-diagnostics">
      <div class="border-b border-white/10 px-4 py-4">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
              Diagnostics
            </p>
            <h3 class="mt-1 text-lg font-semibold text-white">Configuration and runtime notices</h3>
          </div>

          <div class="flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="capture_runtime_snapshot"
              data-test="capture-runtime-snapshot"
              class={session_button_classes(:deactivate, true)}
            >
              Capture runtime snapshot
            </button>
            <button
              type="button"
              phx-click="capture_support_snapshot"
              data-test="capture-support-snapshot"
              class={session_button_classes(:configure, true)}
            >
              Capture support snapshot
            </button>
          </div>
        </div>
      </div>

      <div class="grid gap-4 p-3 sm:p-4 xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]">
        <section class="space-y-2">
          <div :if={@events == []} class="border border-dashed border-white/10 px-4 py-6 text-sm text-slate-400">
            No hardware-scoped notifications yet.
          </div>

          <div :if={@events != []} class="max-h-[34rem] overflow-y-auto space-y-2">
            <article
              :for={event <- Enum.reverse(hardware_events(@events))}
              class="border border-white/8 bg-slate-900/65 px-3 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold text-slate-100">
                    {event.type |> to_string() |> String.replace("_", " ")}
                  </p>
                  <p class="mt-1 truncate font-mono text-[11px] text-slate-500">
                    {event.source |> inspect() |> String.replace_prefix("Elixir.", "")}
                  </p>
                </div>

                <div class="shrink-0 text-right">
                  <p class="font-mono text-[11px] text-slate-500">{format_timestamp(event.occurred_at)}</p>
                </div>
              </div>
            </article>
          </div>
        </section>

        <section class="space-y-2">
          <div class="border border-white/8 bg-slate-900/65 px-3 py-3">
            <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">
              Saved Snapshots
            </p>
            <p class="mt-1 text-sm text-slate-300">
              Freeze the current hardware/runtime truth for later diagnosis, support, or comparison.
            </p>
          </div>

          <div :if={@support_snapshots == []} class="border border-dashed border-white/10 px-4 py-6 text-sm text-slate-400">
            No hardware snapshots captured yet.
          </div>

          <div :if={@support_snapshots != []} class="space-y-2">
            <article
              :for={snapshot <- Enum.take(@support_snapshots, 6)}
              class="border border-white/8 bg-slate-900/65 px-3 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="truncate text-sm font-semibold text-slate-100">
                    {support_snapshot_label(snapshot.kind)}
                  </p>
                  <p class="mt-1 truncate font-mono text-[11px] text-slate-500">
                    {snapshot.id}
                  </p>
                </div>
                <div class="shrink-0 text-right">
                  <p class="font-mono text-[11px] text-slate-500">{format_timestamp(snapshot.captured_at)}</p>
                </div>
              </div>

              <div class="mt-2 grid gap-2 sm:grid-cols-2">
                <.detail_panel title="State" body={humanize_context(snapshot.summary.state)} />
                <.detail_panel title="Source" body={humanize_source(snapshot.summary.source)} />
                <.detail_panel title="Mode" body={humanize_context(snapshot.summary.mode)} />
                <.detail_panel title="Write Policy" body={humanize_context(snapshot.summary.write_policy)} />
                <.detail_panel title="Slaves" body={Integer.to_string(snapshot.summary.slave_count)} />
                <.detail_panel title="Events" body={Integer.to_string(snapshot.summary.event_count)} />
              </div>

              <div class="mt-3 flex justify-end">
                <button
                  type="button"
                  phx-click="select_support_snapshot"
                  phx-value-snapshot_id={snapshot.id}
                  data-test={"open-support-snapshot-#{snapshot.id}"}
                  class={session_button_classes(:deactivate, true)}
                >
                  Open details
                </button>
              </div>
            </article>
          </div>

          <div
            :if={@selected_support_snapshot}
            class="border border-cyan-400/18 bg-[#070b10] px-3 py-3"
            data-test="selected-support-snapshot"
          >
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
                  Selected Snapshot
                </p>
                <p class="mt-1 text-sm font-semibold text-white">
                  {support_snapshot_label(@selected_support_snapshot.kind)}
                </p>
                <p class="mt-1 font-mono text-[11px] text-slate-500">
                  {@selected_support_snapshot.id}
                </p>
              </div>

              <p class="font-mono text-[11px] text-slate-500">
                {format_timestamp(@selected_support_snapshot.captured_at)}
              </p>
            </div>

            <div class="mt-3 grid gap-2 sm:grid-cols-2">
              <.detail_panel title="State" body={humanize_context(@selected_support_snapshot.summary.state)} />
              <.detail_panel title="Source" body={humanize_source(@selected_support_snapshot.summary.source)} />
              <.detail_panel title="Mode" body={humanize_context(@selected_support_snapshot.summary.mode)} />
              <.detail_panel title="Write Policy" body={humanize_context(@selected_support_snapshot.summary.write_policy)} />
              <.detail_panel title="Hardware Configs" body={support_snapshot_saved_configs(@selected_support_snapshot)} />
              <.detail_panel title="Recent Events" body={support_snapshot_event_types(@selected_support_snapshot)} />
            </div>

            <div class="mt-3 flex justify-end">
              <.link
                href={~p"/studio/hardware/support_snapshots/#{@selected_support_snapshot.id}/download"}
                data-test="download-selected-support-snapshot"
                class={session_button_classes(:configure, true)}
              >
                Download JSON
              </.link>
            </div>
          </div>
        </section>
      </div>
    </section>
    """
  end

  defp capture_support_snapshot(socket, kind) do
    {:ok, snapshot} =
      Session.capture_support_snapshot(%{
        kind: kind,
        context: socket.assigns.hardware_context,
        ethercat: socket.assigns.ethercat,
        events: socket.assigns.events,
        saved_configs: socket.assigns.saved_configs
      })

    socket
    |> assign(:hardware_feedback_ref, nil)
    |> assign(:selected_support_snapshot_id, snapshot.id)
    |> assign(:hardware_feedback, support_snapshot_feedback(:ok, snapshot))
    |> maybe_load_hardware_state()
  end

  defp support_snapshot_feedback(:ok, snapshot) do
    %{
      status: :ok,
      summary: "#{support_snapshot_label(snapshot.kind)} captured",
      detail: "#{snapshot.id} froze the current hardware context, runtime view, and recent events"
    }
  end

  defp support_snapshot_label(:runtime), do: "Runtime Snapshot"
  defp support_snapshot_label(:support), do: "Support Snapshot"
  defp support_snapshot_label(kind), do: humanize_context(kind)

  defp candidate_label(nil), do: "none"
  defp candidate_label(candidate), do: candidate.build_id

  defp armed_release_label(nil), do: "none"
  defp armed_release_label(release), do: release.version

  defp candidate_config_label(nil), do: "none"
  defp candidate_config_label(candidate), do: "#{candidate.build_id} · #{candidate.config.id}"

  defp armed_config_label(nil), do: "none"
  defp armed_config_label(release), do: "#{release.version} · #{release.config.id}"

  defp candidate_snapshot_label(nil), do: "none"

  defp candidate_snapshot_label(candidate) do
    snapshot_label(candidate.deployment_snapshot)
  end

  defp armed_snapshot_label(nil), do: "none"

  defp armed_snapshot_label(release) do
    snapshot_label(release.deployment_snapshot)
  end

  defp snapshot_label(deployment_snapshot) do
    "#{length(deployment_snapshot.machines)} machine(s) · #{length(deployment_snapshot.topologies)} topology snapshot(s) · #{length(deployment_snapshot.panels)} panel assignment(s)"
  end

  defp candidate_change_class(%{bump: nil}), do: "none"
  defp candidate_change_class(%{bump: bump}), do: to_string(bump)

  defp compact_release_section?(%{observed: %{source: :none}}, %{status: status})
       when status in [:aligned, :unavailable],
       do: true

  defp compact_release_section?(_hardware_context, _candidate_vs_armed_diff), do: false

  defp compact_release_history_label([]), do: "no armed releases yet"

  defp compact_release_history_label(release_history) do
    latest_versions =
      release_history
      |> Enum.take(3)
      |> Enum.map(& &1.version)
      |> Enum.join(", ")

    "#{length(release_history)} release(s) · latest #{latest_versions}"
  end

  defp support_snapshot_saved_configs(snapshot) do
    snapshot.payload
    |> Map.get(:saved_configs, [])
    |> Enum.map(& &1.id)
    |> join_list("none")
  end

  defp support_snapshot_event_types(snapshot) do
    snapshot.payload
    |> Map.get(:events, [])
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.take(5)
    |> Enum.map_join(", ", &humanize_context/1)
    |> case do
      "" -> "none"
      value -> value
    end
  end

  attr(:ethercat, :map, required: true)
  attr(:slave_forms, :map, required: true)
  attr(:hardware_context, :map, required: true)

  defp provisioning_section(assigns) do
    ~H"""
    <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]" data-test="hardware-section-provisioning">
      <div class="border-b border-white/10 px-4 py-4 sm:px-5">
        <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
          Provisioning
        </p>
        <h3 class="mt-1 text-lg font-semibold text-white">Per-slave PREOP configuration</h3>
        <p class="mt-1 text-sm text-slate-400">
          `configure_slave/2` is only valid while the EtherCAT session is held in PREOP. Configure process-data registration here, then activate when the ring is ready.
        </p>
      </div>

      <div class="p-3 sm:p-4">
        <div :if={action_notice(@hardware_context, :provisioning)} class="mb-3 border border-amber-300/20 bg-amber-300/8 px-3 py-2 text-[12px] text-amber-50">
          {action_notice(@hardware_context, :provisioning)}
        </div>

        <div :if={@ethercat.slaves == []} class="border border-dashed border-white/15 bg-slate-900/55 px-6 py-10 text-center">
          <h4 class="text-lg font-semibold text-white">No EtherCAT session detected</h4>
          <p class="mt-2 text-sm text-slate-400">
            Start the EtherCAT runtime first. The page will populate with discovered slaves and runtime diagnostics automatically.
          </p>
        </div>

        <div :if={@ethercat.slaves != []} class="space-y-3">
          <article
            :for={slave <- @ethercat.slaves}
            class="border border-white/10 bg-slate-950/70 p-4 shadow-[0_20px_50px_-42px_rgba(0,0,0,0.95)]"
          >
            <div class="flex flex-col gap-3 border-b border-white/10 pb-3 xl:flex-row xl:items-start xl:justify-between">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <h4 class="text-lg font-semibold tracking-[0.04em] text-white">{slave.name}</h4>
                  <StatusBadge.badge status={slave_health(slave)} />
                </div>
                <p class="mt-1 font-mono text-[11px] text-slate-500">
                  station={slave.station} driver={slave_driver(slave)}
                </p>
              </div>

              <div class="grid gap-2 sm:grid-cols-3">
                <.mini_stat label="AL State" value={slave_al_state(slave)} />
                <.mini_stat label="Device Type" value={slave_device_type(slave)} />
                <.mini_stat label="Signals" value={slave_signal_count(slave)} />
              </div>
            </div>

            <div class="mt-3 grid gap-3 2xl:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
              <div class="grid gap-2 sm:grid-cols-2">
                <.detail_panel title="Capabilities" body={join_list(slave_capabilities(slave), "none")} />
                <.detail_panel title="Fault" body={format_term(slave.fault, "none")} />
                <.detail_panel title="PDO Health" body={slave_pdo_health(slave)} />
                <.detail_panel title="Driver Error" body={slave_driver_error(slave)} />
                <.detail_panel title="Observed Signals" body={observed_signal_summary(slave.hardware_snapshot)} />
                <.detail_panel title="Driven Outputs" body={driven_output_summary(slave.hardware_snapshot)} />
              </div>

              <form
                phx-change="change_slave_config"
                phx-submit="save_slave_config"
                id={"slave-config-#{slave.name}"}
                data-test={"slave-config-#{slave.name}"}
                class="grid gap-3 border border-white/8 bg-[#070b10] p-3"
              >
                <input type="hidden" name="slave_config[slave]" value={to_string(slave.name)} />
                <fieldset disabled={!provisioning_allowed?(@hardware_context)} class="contents">
                <div class="grid gap-3 md:grid-cols-2">
                  <label class="space-y-1.5">
                    <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Driver</span>
                    <input
                      type="text"
                      name="slave_config[driver]"
                      value={form_value(@slave_forms, slave.name, "driver")}
                      class={input_classes()}
                    />
                  </label>

                  <label class="space-y-1.5">
                    <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Target State</span>
                    <select
                      name="slave_config[target_state]"
                      class={input_classes()}
                    >
                      <option
                        value="op"
                        selected={select_value?(form_value(@slave_forms, slave.name, "target_state"), "op")}
                      >
                        op
                      </option>
                      <option
                        value="preop"
                        selected={select_value?(form_value(@slave_forms, slave.name, "target_state"), "preop")}
                      >
                        preop
                      </option>
                    </select>
                  </label>

                  <label class="space-y-1.5">
                    <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Process Data</span>
                    <select
                      name="slave_config[process_data_mode]"
                      class={input_classes()}
                    >
                      <option
                        value="none"
                        selected={select_value?(form_value(@slave_forms, slave.name, "process_data_mode"), "none")}
                      >
                        none
                      </option>
                      <option
                        value="all"
                        selected={select_value?(form_value(@slave_forms, slave.name, "process_data_mode"), "all")}
                      >
                        all
                      </option>
                      <option
                        value="signals"
                        selected={select_value?(form_value(@slave_forms, slave.name, "process_data_mode"), "signals")}
                      >
                        signals
                      </option>
                    </select>
                  </label>

                  <label class="space-y-1.5">
                    <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Health Poll ms</span>
                    <input
                      type="text"
                      name="slave_config[health_poll_ms]"
                      value={form_value(@slave_forms, slave.name, "health_poll_ms")}
                      class={input_classes()}
                    />
                  </label>
                </div>

                <label class="space-y-1.5">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">All-domain target</span>
                  <input
                    type="text"
                    name="slave_config[process_data_domain]"
                    value={form_value(@slave_forms, slave.name, "process_data_domain")}
                    class={input_classes()}
                  />
                  <span class="text-[11px] text-slate-500">
                    Known domains: {join_list(domain_names(@ethercat.domains), "none configured")}
                  </span>
                </label>

                <label class="space-y-1.5">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Signal assignments</span>
                  <textarea
                    name="slave_config[process_data_signals]"
                    rows="5"
                    class={input_classes("min-h-[7.5rem]")}
                  >{form_value(@slave_forms, slave.name, "process_data_signals")}</textarea>
                  <span
                    class="text-[11px] text-slate-500"
                    data-test={"slave-#{slave.name}-signals"}
                  >
                    Use one `signal@domain` per line when `signals` mode is selected.
                  </span>
                </label>

                <div class="flex flex-wrap items-center justify-between gap-2 border-t border-white/8 pt-3">
                  <span class="font-mono text-[10px] uppercase tracking-[0.22em] text-slate-500">
                    Configure in PREOP before activation
                  </span>
                  <button
                    type="submit"
                    data-confirm={confirm_prompt(@hardware_context, :provisioning)}
                    disabled={!provisioning_allowed?(@hardware_context) or !@ethercat.configurable?}
                    class={session_button_classes(:configure, provisioning_allowed?(@hardware_context) and @ethercat.configurable?)}
                  >
                    Apply configuration
                  </button>
                </div>
                </fieldset>
              </form>
            </div>
          </article>
        </div>
      </div>
    </section>
    """
  end

  attr(:feedback, :map, default: nil)

  defp feedback_banner(assigns) do
    ~H"""
    <section :if={@feedback} class="app-panel border-white/10 bg-slate-950/85 px-5 py-4">
      <StudioCell.notice
        tone={feedback_tone(@feedback)}
        title={Map.get(@feedback, :summary, "Hardware feedback")}
        message={Map.get(@feedback, :detail)}
      />
    </section>
    """
  end

  attr(:ethercat, :map, required: true)
  attr(:hardware_context, :map, required: true)
  attr(:simulation_config_form, :map, required: true)
  attr(:effective_simulation_config, :any, required: true)
  attr(:hardware_config_cell, :map, required: true)
  attr(:hardware_config_source, :string, required: true)
  attr(:available_ethercat_drivers, :list, required: true)
  attr(:available_raw_interfaces, :list, required: true)
  attr(:studio_read_only?, :boolean, default: false)

  defp hardware_config_section(assigns) do
    ~H"""
    <StudioCell.cell
      panel_class="border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]"
      data-test="hardware-config-studio"
    >
      <:notice :if={@hardware_config_cell.notice}>
        <StudioCell.notice
          tone={@hardware_config_cell.notice.tone}
          title={@hardware_config_cell.notice.title}
          message={@hardware_config_cell.notice.message}
        />
      </:notice>

      <:views>
        <StudioCell.view_button
          :for={view <- @hardware_config_cell.views}
          type="button"
          phx-click="select_config_view"
          phx-value-view={view.id}
          selected={@hardware_config_cell.selected_view == view.id}
          available={view.available?}
          data-test={"hardware-config-view-#{view.id}"}
        >
          {view.label}
        </StudioCell.view_button>
      </:views>

      <:body>
        <div :if={@hardware_config_cell.selected_view == :source}>
          <.smart_cell_code
            title="Generated hardware config"
            body={@hardware_config_source}
            data_test="hardware-config-source"
          />
        </div>

        <div :if={@hardware_config_cell.selected_view == :visual}>
          <form
            id="hardware-config-form"
            phx-change="change_simulation_config"
            class="grid gap-4 border border-white/8 bg-[#070b10] p-3"
            data-test="hardware-config-form"
          >
            <fieldset
              disabled={!simulation_allowed?(@hardware_context) or @studio_read_only?}
              class="contents"
            >
              <div class="border-b border-white/8 pb-3">
                <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
                  Hardware Config
                </p>
                <p class="mt-1 text-sm text-slate-300">
                  Edit the EtherCAT ring in one place. Both the simulator and the master derive from this config.
                </p>
              </div>

              <div class="grid gap-3 md:grid-cols-2">
                <label class="space-y-1.5">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Config Id</span>
                  <input
                    type="text"
                    name="simulation_config[id]"
                    value={Map.get(@simulation_config_form, "id", "")}
                    class={input_classes()}
                  />
                </label>

                <label class="space-y-1.5">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Label</span>
                  <input
                    type="text"
                    name="simulation_config[label]"
                    value={Map.get(@simulation_config_form, "label", "")}
                    class={input_classes()}
                  />
                </label>

                <label class="space-y-1.5 md:col-span-2">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Transport</span>
                  <select
                    name="simulation_config[transport]"
                    class={input_classes()}
                    data-test="hardware-config-transport"
                  >
                    <option
                      :for={{transport, label} <- master_transport_options(@simulation_config_form, @available_raw_interfaces)}
                      value={transport}
                      selected={select_value?(Map.get(@simulation_config_form, "transport", "udp"), transport)}
                    >
                      {label}
                    </option>
                  </select>
                  <span class="text-[11px] text-slate-500">
                    {master_transport_hint(@simulation_config_form, @available_raw_interfaces)}
                  </span>
                </label>

                <label
                  :if={Map.get(@simulation_config_form, "transport", "udp") == "udp"}
                  class="space-y-1.5"
                >
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Bind IP</span>
                  <input
                    type="text"
                    name="simulation_config[bind_ip]"
                    value={Map.get(@simulation_config_form, "bind_ip", "")}
                    class={input_classes()}
                  />
                </label>

                <label
                  :if={Map.get(@simulation_config_form, "transport", "udp") == "udp"}
                  class="space-y-1.5"
                >
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Simulator IP</span>
                  <input
                    type="text"
                    name="simulation_config[simulator_ip]"
                    value={Map.get(@simulation_config_form, "simulator_ip", "")}
                    class={input_classes()}
                  />
                </label>

                <label
                  :if={Map.get(@simulation_config_form, "transport", "udp") != "udp"}
                  class="space-y-1.5"
                >
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Primary Interface</span>
                  <select
                    name="simulation_config[primary_interface]"
                    class={input_classes()}
                    data-test="hardware-config-primary-interface"
                  >
                    <option
                      :for={interface <- interface_options(Map.get(@simulation_config_form, "primary_interface", ""), @available_raw_interfaces)}
                      value={interface}
                      selected={select_value?(Map.get(@simulation_config_form, "primary_interface", ""), interface)}
                    >
                      {interface_label(interface)}
                    </option>
                  </select>
                </label>

                <label
                  :if={Map.get(@simulation_config_form, "transport", "udp") == "redundant"}
                  class="space-y-1.5"
                >
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Secondary Interface</span>
                  <select
                    name="simulation_config[secondary_interface]"
                    class={input_classes()}
                    data-test="hardware-config-secondary-interface"
                  >
                    <option
                      :for={interface <- interface_options(Map.get(@simulation_config_form, "secondary_interface", ""), @available_raw_interfaces)}
                      value={interface}
                      selected={select_value?(Map.get(@simulation_config_form, "secondary_interface", ""), interface)}
                    >
                      {interface_label(interface)}
                    </option>
                  </select>
                </label>

                <label class="space-y-1.5">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Scan Stable ms</span>
                  <input
                    type="text"
                    name="simulation_config[scan_stable_ms]"
                    value={Map.get(@simulation_config_form, "scan_stable_ms", "")}
                    class={input_classes()}
                  />
                </label>

                <label class="space-y-1.5">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Scan Poll ms</span>
                  <input
                    type="text"
                    name="simulation_config[scan_poll_ms]"
                    value={Map.get(@simulation_config_form, "scan_poll_ms", "")}
                    class={input_classes()}
                  />
                </label>

                <label class="space-y-1.5 md:col-span-2">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Frame Timeout ms</span>
                  <input
                    type="text"
                    name="simulation_config[frame_timeout_ms]"
                    value={Map.get(@simulation_config_form, "frame_timeout_ms", "")}
                    class={input_classes()}
                  />
                </label>
              </div>

              <section class="grid gap-3 border-t border-white/8 pt-4" data-test="hardware-config-watched-slaves">
                <div class="flex flex-wrap items-center justify-between gap-3">
                  <div>
                    <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
                      Slaves
                    </p>
                    <p class="mt-1 text-sm text-slate-300">
                      `Scan` replaces this list from the observed bus. You can then refine names, drivers, and startup targets before starting the master.
                    </p>
                  </div>

                  <button
                    type="button"
                    phx-click="add_simulation_slave"
                    class={session_button_classes(:configure, simulation_allowed?(@hardware_context) and not @studio_read_only?)}
                    data-test="add-hardware-config-slave"
                    disabled={!simulation_allowed?(@hardware_context) or @studio_read_only?}
                  >
                    Add slave
                  </button>
                </div>

                <div class="space-y-2">
                  <div
                    :for={{slave, index} <- Enum.with_index(Map.get(@simulation_config_form, "slaves", []))}
                    class="grid gap-2 rounded-xl border border-white/8 bg-slate-950/70 p-3 md:grid-cols-[minmax(0,0.9fr)_minmax(0,1.2fr)_10rem_auto]"
                    data-test={"hardware-config-slave-row-#{index}"}
                  >
                    <label class="space-y-1.5">
                      <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Name</span>
                      <input
                        type="text"
                        name={"simulation_config[slaves][#{index}][name]"}
                        value={Map.get(slave, "name", "")}
                        class={input_classes()}
                      />
                    </label>

                    <label class="space-y-1.5">
                      <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Driver</span>
                      <select
                        name={"simulation_config[slaves][#{index}][driver]"}
                        class={input_classes()}
                      >
                        <option
                          :for={driver <- driver_options(Map.get(slave, "driver", ""), recommended_driver_for_row(slave, index, @ethercat), @available_ethercat_drivers)}
                          value={driver}
                          selected={select_value?(Map.get(slave, "driver", ""), driver)}
                        >
                          {driver}
                        </option>
                      </select>
                      <span class="text-[11px] text-slate-500">
                        {driver_recommendation_label(recommended_driver_for_row(slave, index, @ethercat), Map.get(slave, "driver", ""))}
                      </span>
                    </label>

                    <label class="space-y-1.5">
                      <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Start In</span>
                      <select
                        name={"simulation_config[slaves][#{index}][target_state]"}
                        class={input_classes()}
                      >
                        <option value="op" selected={select_value?(Map.get(slave, "target_state", "op"), "op")}>
                          op
                        </option>
                        <option value="preop" selected={select_value?(Map.get(slave, "target_state", "op"), "preop")}>
                          preop
                        </option>
                      </select>
                    </label>

                    <div class="flex items-end justify-end">
                      <button
                        type="button"
                        phx-click="remove_simulation_slave"
                        phx-value-index={index}
                        class={session_button_classes(:deactivate, simulation_allowed?(@hardware_context) and not @studio_read_only?)}
                        data-test={"remove-hardware-config-slave-#{index}"}
                        disabled={!simulation_allowed?(@hardware_context) or @studio_read_only?}
                      >
                        Remove
                      </button>
                    </div>
                  </div>
                </div>
              </section>
            </fieldset>
          </form>
        </div>
      </:body>
    </StudioCell.cell>
    """
  end

  attr(:hardware_context, :map, required: true)
  attr(:simulation_config_form, :map, required: true)

  defp simulator_runtime_section(assigns) do
    running? = Map.get(assigns.hardware_context.observed, :source) == :simulator

    assigns =
      assigns
      |> assign(:running?, running?)
      |> assign(:config_id, Map.get(assigns.simulation_config_form, "id", "ethercat_demo"))

    ~H"""
    <section
      class="app-panel border-white/10 bg-slate-950/85 px-5 py-5 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]"
      data-test="hardware-section-simulator"
    >
      <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
            Simulator
          </p>
          <h3 class="mt-1 text-lg font-semibold text-white">Derived runtime from current hardware config</h3>
          <p class="mt-1 max-w-3xl text-sm text-slate-300">
            Start or stop the EtherCAT simulator against the current hardware config draft. Edit the config above; this panel only executes it.
          </p>
        </div>

        <button
          :if={!@running?}
          type="button"
          phx-click="start_simulation"
          class={session_button_classes(:activate, simulation_allowed?(@hardware_context))}
          data-test="start-simulation"
          disabled={!simulation_allowed?(@hardware_context)}
        >
          Start simulation
        </button>

        <button
          :if={@running?}
          type="button"
          phx-click="stop_simulation"
          class={session_button_classes(:deactivate, simulation_allowed?(@hardware_context))}
          data-test="stop-simulation"
          disabled={!simulation_allowed?(@hardware_context)}
        >
          Stop simulation
        </button>
      </div>

      <div class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.detail_panel title="Config" body={@config_id} />
        <.detail_panel title="Transport" body={simulation_transport_summary(@simulation_config_form)} />
        <.detail_panel title="Timing" body={simulation_timing_summary(@simulation_config_form)} />
        <.detail_panel title="Domains" body={simulation_domain_summary(@simulation_config_form)} />
      </div>
    </section>
    """
  end

  attr(:ethercat, :map, required: true)
  attr(:hardware_context, :map, required: true)

  defp master_runtime_section(assigns) do
    master_running? = master_running?(assigns.ethercat)

    notice =
      cond do
        master_running? ->
          {"Master runtime is active",
           "The running master currently reflects the attached runtime. Change the hardware config above, then restart the master when you want the new draft to take effect."}

        assigns.hardware_context.observed.source == :simulator ->
          {"Simulator backend is still running",
           "Start the master to attach to the simulated ring and validate the current hardware config."}

        true ->
          {"No active master runtime",
           "Scan and start the master when you want to execute the current hardware config against the available backend."}
      end

    assigns =
      assigns
      |> assign(:master_running?, master_running?)
      |> assign(:notice_title, elem(notice, 0))
      |> assign(:notice_message, elem(notice, 1))

    ~H"""
    <section
      class="app-panel border-white/10 bg-slate-950/85 px-5 py-5 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]"
      data-test="hardware-section-master"
    >
      <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
        <div>
          <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
            EtherCAT Master
          </p>
          <h3 class="mt-1 text-lg font-semibold text-white">Runtime derived from current hardware config</h3>
          <p class="mt-1 max-w-3xl text-sm text-slate-300">
            Scan, start, and stop the master from the current hardware config. Runtime control lives here; source ownership stays above.
          </p>
        </div>

        <div class="flex flex-wrap gap-2">
          <button
            :if={!@master_running?}
            type="button"
            phx-click="scan_master"
            class={session_button_classes(:configure, true)}
            data-test="master-scan"
          >
            Scan
          </button>

          <button
            :if={!@master_running?}
            type="button"
            phx-click="start_master"
            class={session_button_classes(:activate, true)}
            data-test="start-master"
          >
            Start master
          </button>

          <button
            :if={@master_running?}
            type="button"
            phx-click="stop_master"
            class={session_button_classes(:deactivate, true)}
            data-test="stop-master"
          >
            Stop master
          </button>
        </div>
      </div>

      <div class="mt-4">
        <StudioCell.notice tone={if(@master_running?, do: :info, else: :info)} title={@notice_title} message={@notice_message} />
      </div>

      <div :if={@master_running?} class="mt-4">
        <.master_runtime_view ethercat={@ethercat} />
      </div>
    </section>
    """
  end

  defp load_hardware_state(socket) do
    ethercat = Session.ethercat_session()
    selected_hardware_config = selected_hardware_config(socket)
    saved_configs = List.wrap(selected_hardware_config)
    current_candidate_release = Session.current_candidate_release()
    current_armed_release = Session.current_armed_release()
    release_history = Session.release_history()
    support_snapshots = Session.list_support_snapshots()
    events = socket.assigns[:events] || Session.recent_events(@event_limit)

    simulation_config_form =
      socket.assigns[:simulation_config_form]
      |> Kernel.||(selected_hardware_config_form(socket))
      |> Kernel.||(Session.default_ethercat_simulation_form())
      |> normalize_simulation_config_form()

    {effective_simulation_config, hardware_config_error, hardware_config_source} =
      case Session.preview_ethercat_simulation_config(simulation_config_form) do
        {:ok, config} ->
          {config, nil, HardwareConfigSource.to_source(config)}

        {:error, reason} ->
          {nil, reason, invalid_hardware_config_source(simulation_config_form, reason)}
      end

    hardware_context =
      Session.build_hardware_context(ethercat, events, saved_configs,
        mode: socket.assigns[:mode_override]
      )

    live_hardware_preview =
      case hardware_context.observed.source do
        :live ->
          case Session.preview_ethercat_hardware_config(
                 socket.assigns[:capture_config_form] || %{}
               ) do
            {:ok, config} -> config
            {:error, _reason} -> nil
          end

        _other ->
          nil
      end

    draft_live_diff =
      Session.compare_hardware_draft_to_live(simulation_config_form, live_hardware_preview)

    candidate_vs_armed_diff = Session.candidate_vs_armed_diff()

    selected_support_snapshot_id =
      socket.assigns[:selected_support_snapshot_id] ||
        first_support_snapshot_id(support_snapshots)

    selected_support_snapshot =
      resolve_support_snapshot(selected_support_snapshot_id, support_snapshots)

    assign(socket,
      ethercat: ethercat,
      slave_forms: merge_slave_forms(socket.assigns[:slave_forms] || %{}, ethercat.slaves),
      available_raw_interfaces: Session.available_raw_interfaces(),
      capture_config_form:
        socket.assigns[:capture_config_form]
        |> Kernel.||(default_capture_config_form())
        |> normalize_capture_config_form(),
      simulation_config_form: simulation_config_form,
      effective_simulation_config: effective_simulation_config,
      hardware_config_error: hardware_config_error,
      hardware_config_source: hardware_config_source,
      saved_configs: saved_configs,
      current_candidate_release: current_candidate_release,
      current_armed_release: current_armed_release,
      candidate_vs_armed_diff: candidate_vs_armed_diff,
      release_history: release_history,
      support_snapshots: support_snapshots,
      selected_support_snapshot_id: selected_support_snapshot_id,
      selected_support_snapshot: selected_support_snapshot,
      hardware_context: hardware_context,
      live_hardware_preview: live_hardware_preview,
      draft_live_diff: draft_live_diff
    )
  end

  defp maybe_load_hardware_state(socket) do
    load_hardware_state(socket)
  rescue
    error in UndefinedFunctionError ->
      if error.module == HardwareGateway do
        socket
      else
        reraise error, __STACKTRACE__
      end
  end

  defp maybe_reset_revision_simulation_form(socket, previous_revision) do
    current_revision = socket.assigns[:studio_selected_revision]

    if current_revision == previous_revision do
      socket
    else
      assign(socket, :simulation_config_form, selected_hardware_config_form(socket))
    end
  end

  defp maybe_persist_simulation_form(socket, form) do
    case Session.preview_ethercat_simulation_config(form) do
      {:ok, config} ->
        _ = maybe_persist_workspace_hardware_config(socket, config)
        SessionSync.refresh(socket)

      {:error, _reason} ->
        socket
    end
  end

  defp persist_current_simulation_form(socket) do
    maybe_persist_simulation_form(socket, socket.assigns.simulation_config_form)
  end

  defp selected_hardware_config_form(socket) do
    case selected_hardware_config(socket) do
      %HardwareConfig{} = config -> config_form_from_config(config)
      _other -> Session.default_ethercat_simulation_form()
    end
  end

  defp selected_hardware_config(socket), do: SessionSync.current_hardware_config(socket)

  defp maybe_persist_workspace_hardware_config(socket, %HardwareConfig{} = config) do
    cond do
      StudioRevision.read_only?(socket) ->
        :ok

      not workspace_hardware_config_roundtrip_safe?(socket) ->
        :ok

      true ->
        case Session.put_hardware_config(config) do
          :error -> :error
          _draft -> :ok
        end
    end
  end

  defp master_runtime_input(socket) do
    workspace_runtime_input(socket)
  end

  defp simulation_runtime_input(socket) do
    workspace_runtime_input(socket)
  end

  defp simulation_runtime_input_id(%HardwareConfig{id: id}, _fallback) when is_binary(id), do: id

  defp simulation_runtime_input_id(input, fallback) when is_map(input),
    do: Map.get(input, "id", fallback)

  defp simulation_runtime_input_id(_input, fallback), do: fallback

  defp workspace_hardware_config_roundtrip_safe?(socket) do
    match?(%{sync_state: :synced}, SessionSync.fetch_hardware_config(socket))
  end

  defp merge_slave_forms(existing_forms, slave_rows) do
    Enum.reduce(slave_rows, existing_forms, fn slave, acc ->
      Map.put_new(acc, to_string(slave.name), slave.form_defaults)
    end)
  end

  defp dispatch_hardware_action_async(live_pid, ref, fun) do
    Task.start(fn ->
      result = fun.()

      feedback =
        case result do
          {:ok, feedback} -> feedback
          {:error, feedback} -> feedback
        end

      send(live_pid, {:hardware_action_result, ref, feedback})
    end)
  end

  defp schedule_hardware_refresh do
    Process.send_after(self(), :refresh_hardware, @refresh_interval_ms)
  end

  defp mode_override_from_params(params), do: parse_hardware_mode(Map.get(params, "mode"))

  defp hardware_mode_path(mode, selected_revision) when is_atom(mode) do
    hardware_mode_path(%{"mode" => Atom.to_string(mode)}, selected_revision)
  end

  defp hardware_mode_path(params, selected_revision) do
    query =
      %{}
      |> maybe_put_query("mode", normalize_mode_param(Map.get(params, "mode")))
      |> maybe_put_query("revision", selected_revision)

    ~p"/studio/hardware?#{query}"
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp normalize_mode_param(nil), do: nil

  defp normalize_mode_param(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_hardware_mode(nil), do: nil

  defp parse_hardware_mode(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "testing" -> :testing
      "armed" -> :armed
      _other -> nil
    end
  end

  defp parse_config_view(nil), do: :visual

  defp parse_config_view(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "visual" -> :visual
      "source" -> :source
      _other -> :visual
    end
  end

  defp parse_slave_name(nil), do: {:error, :missing_slave}

  defp parse_slave_name(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, :missing_slave}
    else
      try do
        {:ok, String.to_existing_atom(trimmed)}
      rescue
        ArgumentError -> {:error, :unknown_slave}
      end
    end
  end

  defp parse_deactivate_target("safeop"), do: {:ok, :safeop}
  defp parse_deactivate_target("preop"), do: {:ok, :preop}
  defp parse_deactivate_target(_value), do: {:error, :invalid_target}

  defp configure_feedback(:pending, slave_name, _spec) do
    %{
      status: :pending,
      summary: "applying EtherCAT configuration for #{slave_name}",
      detail: "waiting for PREOP configuration to finish on #{slave_name}"
    }
  end

  defp configure_feedback(:ok, slave_name, spec) do
    %{
      status: :ok,
      summary: "hardware configuration applied for #{slave_name}",
      detail:
        "driver=#{inspect(spec.driver)} process_data=#{inspect(spec.process_data)} target_state=#{spec.target_state} health_poll_ms=#{inspect(spec.health_poll_ms)}"
    }
  end

  defp configure_feedback(:error, slave_name, reason) do
    %{
      status: :error,
      summary: "hardware configuration failed for #{slave_name}",
      detail: inspect(reason)
    }
  end

  defp master_scan_feedback(:ok, form) do
    %{
      status: :ok,
      summary: "master scan synced from live bus",
      detail:
        "#{simulation_domain_summary(form)} · watched #{watched_slave_count(form)} slave(s): #{watched_slave_summary(form)}"
    }
  end

  defp master_scan_feedback(:error, reason) do
    %{
      status: :error,
      summary: "master scan failed",
      detail: inspect(reason)
    }
  end

  defp master_feedback(:ok, :start, runtime) do
    %{
      status: :ok,
      summary: "EtherCAT master started",
      detail:
        "state=#{inspect(runtime.state)} watched=#{Enum.join(Enum.map(runtime.slaves, &to_string/1), ", ")}",
      config: runtime.config
    }
  end

  defp master_feedback(:error, :start, reason) do
    %{
      status: :error,
      summary: "EtherCAT master start failed",
      detail: inspect(reason)
    }
  end

  defp master_feedback(:ok, :stop, _detail) do
    %{
      status: :ok,
      summary: "EtherCAT master stopped",
      detail: "the EtherCAT runtime is stopped"
    }
  end

  defp master_feedback(:error, :stop, reason) do
    %{
      status: :error,
      summary: "EtherCAT master stop failed",
      detail: inspect(reason)
    }
  end

  defp session_feedback(:pending, :activate, _detail) do
    %{
      status: :pending,
      summary: "activating EtherCAT session",
      detail: "driving the ring toward operational runtime"
    }
  end

  defp session_feedback(:ok, :activate, _detail) do
    %{
      status: :ok,
      summary: "EtherCAT activate sent",
      detail: "the session accepted the activate request"
    }
  end

  defp session_feedback(:error, :activate, reason) do
    %{status: :error, summary: "EtherCAT activate failed", detail: inspect(reason)}
  end

  defp session_feedback(:pending, :deactivate, target) do
    %{
      status: :pending,
      summary: "retreating EtherCAT session to #{target}",
      detail: "waiting for runtime retreat to complete"
    }
  end

  defp session_feedback(:ok, :deactivate, target) do
    %{
      status: :ok,
      summary: "EtherCAT retreat sent",
      detail: "session accepted retreat to #{target}"
    }
  end

  defp session_feedback(:error, :deactivate, {target, reason}) do
    %{status: :error, summary: "EtherCAT retreat to #{target} failed", detail: inspect(reason)}
  end

  defp capture_feedback(:pending, _config) do
    %{
      status: :pending,
      summary: "capturing live hardware as a config",
      detail: "reading detected domains, slaves, and driver state into a reusable hardware_config"
    }
  end

  defp capture_feedback(:ok, config) do
    %{
      status: :ok,
      summary: "captured live hardware as #{config.id}",
      detail:
        "#{config.label} now replaces the workspace hardware config and stages the simulator from that source",
      config: config
    }
  end

  defp capture_feedback(:error, reason) do
    %{
      status: :error,
      summary: "live hardware capture failed",
      detail: inspect(reason)
    }
  end

  defp clone_feedback(:ok, config) do
    %{
      status: :ok,
      summary: "cloned live hardware into the draft editor",
      detail: "#{config.label} is staged as the current workspace hardware config"
    }
  end

  defp clone_feedback(:error, reason) do
    %{
      status: :error,
      summary: "clone live to draft failed",
      detail: inspect(reason)
    }
  end

  defp candidate_feedback(:ok, candidate) do
    %{
      status: :ok,
      summary: "candidate #{candidate.build_id} promoted",
      detail: "#{candidate.config.id} is now the current hardware candidate"
    }
  end

  defp candidate_feedback(:error, reason) do
    %{
      status: :error,
      summary: "candidate promotion failed",
      detail: inspect(reason)
    }
  end

  defp candidate_release_feedback(:ok, release) do
    %{
      status: :ok,
      summary: "armed release #{release.version}",
      detail:
        "candidate #{release.candidate_build_id} is now the armed baseline with #{release.bump} classification"
    }
  end

  defp candidate_release_feedback(:error, reason) do
    %{
      status: :error,
      summary: "arm candidate failed",
      detail: inspect(reason)
    }
  end

  defp rollback_feedback(:ok, release) do
    %{
      status: :ok,
      summary: "rolled back to #{release.version}",
      detail: "release #{release.version} is now the armed baseline again"
    }
  end

  defp rollback_feedback(:error, reason) do
    %{
      status: :error,
      summary: "rollback failed",
      detail: inspect(reason)
    }
  end

  defp simulation_feedback(:ok, config_id, runtime) do
    %{
      status: :ok,
      summary: "simulation started from #{config_id}",
      detail:
        "simulator port=#{runtime.port} slaves=#{Enum.join(Enum.map(runtime.slaves, &to_string/1), ", ")}"
    }
  end

  defp simulation_feedback(:error, config_id, reason) do
    %{
      status: :error,
      summary: "simulation start failed for #{config_id}",
      detail: inspect(reason)
    }
  end

  defp simulation_feedback(:ok, config_id, runtime, config) do
    simulation_feedback(:ok, config_id, runtime)
    |> Map.put(:config, config)
  end

  defp simulation_stop_feedback(:ok, config_id) do
    %{
      status: :ok,
      summary: "simulation stopped for #{config_id}",
      detail: "the EtherCAT simulator and master runtime are stopped"
    }
  end

  defp simulation_stop_feedback(:error, config_id, reason) do
    %{
      status: :error,
      summary: "simulation stop failed for #{config_id}",
      detail: inspect(reason)
    }
  end

  defp invalid_feedback(action, reason) do
    %{status: :error, summary: "#{action} rejected by HMI", detail: inspect(reason)}
  end

  defp deny_hardware_action(socket, action) do
    assign(
      socket,
      :hardware_feedback,
      %{
        status: :error,
        summary: "#{action} blocked by write policy",
        detail:
          "write_policy=#{socket.assigns.hardware_context.mode.write_policy} authority=#{socket.assigns.hardware_context.mode.authority_scope}"
      }
    )
  end

  defp readonly_hardware(socket) do
    assign(socket, :hardware_feedback, %{
      status: :warning,
      summary: StudioRevision.readonly_title(),
      detail: StudioRevision.readonly_message()
    })
  end

  defp maybe_assign_revision_target_feedback(socket) do
    case {socket.assigns[:studio_selected_revision], socket.assigns[:hardware_feedback]} do
      {revision, nil} when is_binary(revision) and revision != "" ->
        assign(socket, :hardware_feedback, revision_target_feedback())

      {revision, %{kind: :revision_target_scope}}
      when is_binary(revision) and revision != "" ->
        assign(socket, :hardware_feedback, revision_target_feedback())

      {_revision, %{kind: :revision_target_scope}} ->
        assign(socket, :hardware_feedback, nil)

      _other ->
        socket
    end
  end

  defp revision_target_feedback do
    %{
      kind: :revision_target_scope,
      status: :info,
      summary: "Workspace session loaded from revision",
      detail:
        "This hardware shell is showing the shared workspace session after loading the selected revision into it."
    }
  end

  defp humanize_context(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp humanize_context(value) when is_binary(value), do: value
  defp humanize_context(value), do: inspect(value)

  defp humanize_source(:live), do: "Live Hardware"
  defp humanize_source(:simulator), do: "Simulator"
  defp humanize_source(:none), do: "No Backend"
  defp humanize_source(value), do: humanize_context(value)

  defp mode_label(%{mode: %{kind: :armed}}), do: "Armed"
  defp mode_label(%{observed: %{source: :live}}), do: "Live Inspect"
  defp mode_label(_hardware_context), do: "Draft / Test"

  defp select_value?(current, expected) do
    to_string(current || "") == to_string(expected || "")
  end

  defp master_transport_options(form, available_interfaces) do
    current_transport = Map.get(form, "transport", "udp")

    base_options =
      [{"udp", "UDP"}]
      |> maybe_append_transport_option("raw", "Raw Socket", available_interfaces != [])
      |> maybe_append_transport_option(
        "redundant",
        "Redundant",
        length(available_interfaces) >= 2
      )

    if Enum.any?(base_options, fn {transport, _label} -> transport == current_transport end) do
      base_options
    else
      base_options ++ [{current_transport, "#{humanize_context(current_transport)} (current)"}]
    end
  end

  defp maybe_append_transport_option(options, _transport, _label, false), do: options

  defp maybe_append_transport_option(options, transport, label, true) do
    options ++ [{transport, label}]
  end

  defp master_transport_hint(form, available_interfaces) do
    transport = Map.get(form, "transport", "udp")

    cond do
      transport == "udp" and available_interfaces == [] ->
        "No raw interfaces detected. UDP remains available for simulator-backed master sessions."

      transport == "udp" ->
        "Raw socket and redundant mode are available when you want to attach the master directly to the bus."

      transport == "raw" and available_interfaces == [] ->
        "No raw interfaces are available right now."

      transport == "redundant" and length(available_interfaces) < 2 ->
        "Redundant mode needs two distinct raw-capable interfaces."

      transport == "redundant" ->
        "Choose two different interfaces for the primary and backup bus paths."

      true ->
        "Use the detected interface inventory for direct raw EtherCAT access."
    end
  end

  defp interface_options(current, available_interfaces) do
    options =
      case String.trim(to_string(current || "")) do
        "" ->
          ["" | available_interfaces]

        selected ->
          if selected in available_interfaces do
            ["" | available_interfaces]
          else
            ["", selected | available_interfaces]
          end
      end

    Enum.uniq(options)
  end

  defp interface_label(""), do: "Select interface"
  defp interface_label(interface), do: interface

  defp runtime_control_allowed?(hardware_context) do
    (hardware_context.mode.kind == :armed and
       hardware_context.observed.source == :live and
       hardware_context.mode.write_policy == :confirmed) or
      (hardware_context.mode.kind == :testing and
         hardware_context.observed.source == :simulator and
         hardware_context.mode.write_policy == :enabled)
  end

  defp provisioning_allowed?(hardware_context) do
    runtime_control_allowed?(hardware_context)
  end

  defp simulation_allowed?(hardware_context) do
    hardware_context.mode.kind == :testing and
      hardware_context.mode.write_policy == :enabled and
      hardware_context.observed.source in [:none, :simulator]
  end

  defp candidate_promotion_allowed?(hardware_context) do
    simulation_allowed?(hardware_context)
  end

  defp candidate_arm_allowed?(hardware_context, candidate_release) do
    not is_nil(candidate_release) and
      hardware_context.mode.kind == :armed and
      hardware_context.observed.source == :live and
      hardware_context.mode.write_policy == :confirmed
  end

  defp release_rollback_allowed?(hardware_context, current_armed_release) do
    not is_nil(current_armed_release) and
      hardware_context.mode.kind == :armed and
      hardware_context.observed.source == :live and
      hardware_context.mode.write_policy == :confirmed
  end

  defp capture_allowed?(hardware_context) do
    hardware_context.observed.source == :live and
      hardware_context.mode.write_policy in [:restricted, :confirmed]
  end

  defp confirm_prompt(hardware_context, action)

  defp confirm_prompt(%{mode: %{write_policy: :confirmed}}, :provisioning) do
    "Confirm live hardware configuration change?"
  end

  defp confirm_prompt(_hardware_context, _action), do: nil

  defp action_notice(hardware_context, :provisioning) do
    cond do
      provisioning_allowed?(hardware_context) and
          hardware_context.observed.source == :simulator ->
        "Provisioning changes are enabled against the simulator-backed runtime in testing."

      provisioning_allowed?(hardware_context) ->
        "Provisioning changes are available in armed mode and require explicit confirmation."

      hardware_context.observed.source == :live ->
        "Provisioning changes are blocked in testing mode. Capture or compare first, then switch to armed for confirmed live edits."

      true ->
        "Provisioning changes are blocked by the current write policy."
    end
  end

  defp action_notice(hardware_context, :capture) do
    cond do
      capture_allowed?(hardware_context) ->
        "Capture is safe in both testing and armed modes because it only reads live topology and stores a reusable config baseline."

      hardware_context.observed.source in [:none, :simulator] ->
        "Capture requires connected live hardware."

      true ->
        "Live capture is unavailable in the current context."
    end
  end

  defp candidate_promotion_notice(hardware_context) do
    cond do
      candidate_promotion_allowed?(hardware_context) ->
        "Draft promotion is enabled in testing when the backend is none or simulator-backed."

      hardware_context.observed.source == :live ->
        "Live hardware keeps candidate promotion blocked here. Clone/capture first, then continue from testing."

      true ->
        "Draft promotion is blocked by the current write policy."
    end
  end

  defp candidate_arm_notice(hardware_context, nil) do
    if hardware_context.mode.kind == :armed and hardware_context.observed.source == :live do
      "Promote a candidate first."
    else
      "Arming requires explicit live armed posture and a promoted candidate."
    end
  end

  defp candidate_arm_notice(hardware_context, candidate_release)
       when not is_nil(candidate_release) do
    if candidate_arm_allowed?(hardware_context, candidate_release) do
      "Arming will mint a new semantic release version and mark it as the armed baseline."
    else
      "Arming is only available from live armed posture with confirmed write policy."
    end
  end

  defp release_rollback_notice(hardware_context, nil) do
    if hardware_context.mode.kind == :armed and hardware_context.observed.source == :live do
      "No armed release exists yet."
    else
      "Rollback is only available from live armed posture with confirmed write policy."
    end
  end

  defp release_rollback_notice(hardware_context, current_armed_release) do
    if release_rollback_allowed?(hardware_context, current_armed_release) do
      "Rollback can re-select an earlier immutable release as the armed baseline."
    else
      "Rollback is only available from live armed posture with confirmed write policy."
    end
  end

  defp current_simulation_config_id(%{observed: %{source: :simulator}}, running_config_id, form) do
    running_config_id || Map.get(form, "id", "draft")
  end

  defp current_simulation_config_id(_hardware_context, _running_config_id, _form), do: nil

  attr(:ethercat, :map, required: true)

  defp master_runtime_view(assigns) do
    ~H"""
    <div
      class="grid gap-4 border border-white/8 bg-[#070b10] p-4"
      data-test="master-runtime-view"
    >
      <div class="border-b border-white/8 pb-3">
        <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
          Current master runtime
        </p>
        <p class="mt-1 text-sm text-slate-300">
          This view shows what the attached EtherCAT master is doing now. Switch back to
          <span class="font-medium text-white">Visual</span> to change the next-start draft.
        </p>
      </div>

      <div class="grid gap-2 sm:grid-cols-2 xl:grid-cols-4">
        <.detail_panel title="Master State" body={format_result(@ethercat.state)} />
        <.detail_panel title="Bus" body={format_result(@ethercat.bus)} />
        <.detail_panel title="Domains" body={Integer.to_string(domain_count(@ethercat.domains))} />
        <.detail_panel title="Last Failure" body={failure_summary(@ethercat.last_failure)} />
      </div>

      <div class="overflow-hidden border border-white/8 bg-slate-950/70">
        <div class="border-b border-white/8 px-4 py-3">
          <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
            Observed bus slaves
          </p>
        </div>

        <div :if={@ethercat.slaves == []} class="px-4 py-5 text-sm text-slate-400">
          No bus slaves observed yet.
        </div>

        <div :if={@ethercat.slaves != []} class="divide-y divide-white/8">
          <div
            :for={slave <- @ethercat.slaves}
            class="grid gap-3 px-4 py-3 md:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_auto]"
            data-test={"master-runtime-slave-#{slave.name}"}
          >
            <div class="min-w-0">
              <p class="text-sm font-semibold text-slate-100">{slave.name}</p>
              <p class="mt-1 font-mono text-[11px] text-slate-500">
                station={slave.station}
              </p>
            </div>

            <div class="min-w-0 text-sm text-slate-300">
              <p>{slave_driver(slave)}</p>
              <p class="mt-1 text-[12px] text-slate-500">
                al_state={slave_al_state(slave)} fault={format_term(slave.fault, "none")}
              </p>
            </div>

            <div class="flex justify-end">
              <StatusBadge.badge status={slave_health(slave)} />
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp candidate_arm_confirm(candidate, diff) when not is_nil(candidate) do
    "Arm #{candidate.build_id}? This will mint a new release version. Comparison: #{diff.summary}"
  end

  defp candidate_arm_confirm(_candidate, _diff), do: nil

  defp rollback_confirm(release) do
    "Roll back the armed baseline to #{release.version}? This re-selects the earlier immutable release."
  end

  defp format_mismatch_rows([]), do: ["none"]

  defp format_mismatch_rows(rows) do
    Enum.map(rows, fn row ->
      "#{row.name}: expected=#{row.expected} actual=#{row.actual}"
    end)
  end

  defp protocol_status(%{available?: true}), do: :healthy
  defp protocol_status(_protocol), do: :disconnected

  defp slave_health(%{snapshot: {:ok, %{faults: faults}}, info: {:ok, %{al_state: :op}}})
       when faults in [[], nil],
       do: :running

  defp slave_health(%{snapshot: {:ok, %{faults: faults}}, info: {:ok, %{al_state: :preop}}})
       when faults in [[], nil],
       do: :waiting

  defp slave_health(%{snapshot: {:ok, %{faults: faults}}}) when faults not in [[], nil],
    do: :faulted

  defp slave_health(%{fault: fault}) when not is_nil(fault), do: :faulted
  defp slave_health(%{pid: pid}) when is_pid(pid), do: :healthy
  defp slave_health(_slave), do: :disconnected

  defp slave_driver(%{info: {:ok, info}}) do
    case info[:driver] do
      nil -> "unknown"
      driver -> format_module_name(driver)
    end
  end

  defp slave_driver(_slave), do: "unknown"

  defp slave_al_state(%{info: {:ok, info}}), do: format_term(info[:al_state], "unknown")
  defp slave_al_state(_slave), do: "unknown"

  defp slave_device_type(%{info: {:ok, info}}), do: format_term(info[:device_type], "unknown")
  defp slave_device_type(_slave), do: "unknown"

  defp slave_signal_count(%{info: {:ok, info}}), do: length(info[:signals] || [])
  defp slave_signal_count(_slave), do: 0

  defp slave_capabilities(%{info: {:ok, info}}),
    do: Enum.map(info[:capabilities] || [], &to_string/1)

  defp slave_capabilities(_slave), do: []

  defp slave_pdo_health(%{info: {:ok, info}}) do
    case info[:pdo_health] do
      %{state: state} -> to_string(state)
      _ -> "unknown"
    end
  end

  defp slave_pdo_health(_slave), do: "unknown"

  defp slave_driver_error(%{info: {:ok, info}}), do: format_term(info[:driver_error], "none")
  defp slave_driver_error(_slave), do: "none"

  defp observed_signal_summary(nil), do: "none"
  defp observed_signal_summary(snapshot), do: map_preview(snapshot.observed_signals)

  defp driven_output_summary(nil), do: "none"
  defp driven_output_summary(snapshot), do: map_preview(snapshot.driven_outputs)

  defp domain_count({:ok, domains}) when is_list(domains), do: length(domains)
  defp domain_count(_), do: 0

  defp reference_clock_value({:ok, %{name: name, station: station}}),
    do: "#{name || "unknown"} @ #{station}"

  defp reference_clock_value({:error, reason}), do: Atom.to_string(reason)
  defp reference_clock_value(_value), do: "n/a"

  defp dc_lock_value({:ok, %{lock_state: lock_state}}), do: to_string(lock_state)
  defp dc_lock_value({:error, reason}), do: Atom.to_string(reason)
  defp dc_lock_value(_value), do: "n/a"

  defp failure_summary({:ok, nil}), do: "none"
  defp failure_summary({:ok, failure}), do: truncate(inspect(failure, limit: 4), 34)
  defp failure_summary({:error, reason}), do: Atom.to_string(reason)
  defp failure_summary(_value), do: "n/a"

  defp format_result({:ok, value}) when is_atom(value), do: Atom.to_string(value)
  defp format_result({:ok, value}) when is_list(value), do: Integer.to_string(length(value))
  defp format_result({:ok, nil}), do: "none"
  defp format_result({:ok, _value}), do: "ready"
  defp format_result({:error, reason}), do: inspect(reason)
  defp format_result(value) when is_atom(value), do: Atom.to_string(value)
  defp format_result(_value), do: "n/a"

  defp domain_names({:ok, domains}) when is_list(domains),
    do: Enum.map(domains, fn {id, _, _} -> to_string(id) end)

  defp domain_names(_), do: []

  defp format_term(nil, fallback), do: fallback
  defp format_term(value, _fallback) when is_atom(value), do: Atom.to_string(value)
  defp format_term(value, _fallback), do: truncate(inspect(value, limit: 5), 42)

  defp map_preview(map) when map in [%{}, nil], do: "none"

  defp map_preview(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _} -> to_string(key) end)
    |> Enum.take(4)
    |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
    |> Enum.join(", ")
  end

  defp join_list([], fallback), do: fallback
  defp join_list(items, _fallback), do: Enum.join(items, ", ")

  defp first_support_snapshot_id([snapshot | _rest]), do: snapshot.id
  defp first_support_snapshot_id([]), do: nil

  defp resolve_support_snapshot(nil, _snapshots), do: nil

  defp resolve_support_snapshot(snapshot_id, snapshots) do
    Enum.find(snapshots, &(&1.id == snapshot_id)) ||
      Session.get_support_snapshot(snapshot_id)
  end

  defp mismatch_rows([]), do: ["none"]
  defp mismatch_rows(rows), do: rows

  defp live_preview_label(nil), do: "unavailable"
  defp live_preview_label(config), do: "#{config.id} · #{config.label}"

  defp draft_live_diff_badge(:aligned), do: :healthy
  defp draft_live_diff_badge(:different), do: :waiting
  defp draft_live_diff_badge(:unavailable), do: :stale
  defp draft_live_diff_badge(_status), do: :stale

  defp format_timestamp(nil), do: "n/a"

  defp format_timestamp(value) when is_integer(value) do
    value
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  defp form_value(forms, slave_name, key) do
    forms
    |> Map.get(to_string(slave_name), %{})
    |> Map.get(key, "")
  end

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    binary_part(value, 0, max - 1) <> "…"
  end

  defp truncate(value, _max), do: value

  defp hardware_events(events) do
    Enum.filter(events, fn event ->
      event.meta[:bus] == :ethercat or
        event.type in [
          :hardware_config_saved,
          :hardware_configuration_applied,
          :hardware_configuration_failed,
          :hardware_simulation_started,
          :hardware_simulation_failed,
          :hardware_simulation_stopped,
          :hardware_session_control_applied,
          :hardware_session_control_failed
        ]
    end)
  end

  attr(:title, :string, required: true)
  attr(:body, :string, required: true)
  attr(:data_test, :string, default: nil)

  defp smart_cell_code(assigns) do
    ~H"""
    <div class="border border-white/8 bg-[#070b10]" data-test={@data_test}>
      <div class="border-b border-white/8 px-4 py-3">
        <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">{@title}</p>
      </div>
      <pre class="overflow-x-auto px-4 py-4 font-mono text-[12px] leading-6 text-slate-200"><code>{@body}</code></pre>
    </div>
    """
  end

  defp input_classes(extra \\ "") do
    classes = [
      "w-full border border-white/10 bg-slate-900/80 px-3 py-2 font-mono text-[12px] text-slate-100 outline-none transition",
      "placeholder:text-slate-600 focus:border-cyan-400/40 focus:bg-slate-950/90",
      extra
    ]

    Enum.join(classes, " ")
  end

  defp session_button_classes(_kind, false) do
    "cursor-not-allowed border border-white/10 bg-slate-900/60 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-slate-600"
  end

  defp session_button_classes(:activate, true) do
    "border border-emerald-400/25 bg-emerald-400/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-emerald-50 transition hover:border-emerald-300/40 hover:bg-emerald-300/15"
  end

  defp session_button_classes(:deactivate, true) do
    "border border-amber-400/25 bg-amber-400/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-amber-50 transition hover:border-amber-300/40 hover:bg-amber-300/15"
  end

  defp session_button_classes(:configure, true) do
    "border border-cyan-400/25 bg-cyan-400/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-cyan-50 transition hover:border-cyan-300/40 hover:bg-cyan-300/15"
  end

  defp invalid_hardware_config_source(form, reason) do
    config_id =
      form
      |> Map.get("id", "ethercat_demo")
      |> to_string()

    """
    # Hardware config preview is invalid
    # config_id: #{config_id}
    # reason: #{inspect(reason)}
    """
    |> String.trim()
  end

  defp feedback_tone(%{status: status}) when status in [:ok, :pending, :info], do: :info
  defp feedback_tone(%{status: status}) when status in [:warning, :warn], do: :warning
  defp feedback_tone(_feedback), do: :error

  defp master_running?(ethercat) when is_map(ethercat) do
    case Map.get(ethercat, :master_status) do
      %{lifecycle: lifecycle} when lifecycle not in [:stopped, :idle] -> true
      _other -> false
    end
  end

  defp simulation_transport_summary(form) do
    case Map.get(form, "transport", "udp") do
      "raw" ->
        "raw via #{blank_as(Map.get(form, "primary_interface", ""), "unselected interface")}"

      "redundant" ->
        primary = blank_as(Map.get(form, "primary_interface", ""), "primary unset")
        secondary = blank_as(Map.get(form, "secondary_interface", ""), "secondary unset")
        "redundant via #{primary} / #{secondary}"

      _other ->
        bind_ip = blank_as(Map.get(form, "bind_ip", ""), "127.0.0.1")
        simulator_ip = blank_as(Map.get(form, "simulator_ip", ""), "127.0.0.2")
        "udp #{bind_ip} -> #{simulator_ip}"
    end
  end

  defp simulation_timing_summary(form) do
    stable = blank_as(Map.get(form, "scan_stable_ms", ""), "20")
    poll = blank_as(Map.get(form, "scan_poll_ms", ""), "10")
    timeout = blank_as(Map.get(form, "frame_timeout_ms", ""), "20")
    "stable #{stable} ms · poll #{poll} ms · timeout #{timeout} ms"
  end

  defp simulation_domain_summary(form) do
    domain_ids =
      form
      |> normalize_simulation_config_form()
      |> Map.get("domains", [])
      |> Enum.map(&Map.get(&1, "id", ""))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    "#{length(domain_ids)} domain(s): #{join_list(domain_ids, "main")}"
  end

  defp blank_as(value, fallback) when is_binary(value) do
    case String.trim(value) do
      "" -> fallback
      trimmed -> trimmed
    end
  end

  defp blank_as(value, _fallback), do: to_string(value)

  defp watched_slave_count(form) do
    form
    |> normalize_simulation_config_form()
    |> Map.get("slaves", [])
    |> length()
    |> Integer.to_string()
  end

  defp watched_slave_summary(form) do
    rows =
      form
      |> normalize_simulation_config_form()
      |> Map.get("slaves", [])
      |> Enum.map(fn slave ->
        name = Map.get(slave, "name", "") |> String.trim()
        driver = Map.get(slave, "driver", "") |> String.trim()

        case {name, driver} do
          {"", ""} -> nil
          {"", driver} -> driver
          {name, ""} -> name
          {name, driver} -> "#{name} (#{driver})"
        end
      end)
      |> Enum.reject(&is_nil/1)

    join_list(rows, "none")
  end

  defp format_module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end

  defp format_module_name(module) when is_binary(module), do: module
  defp format_module_name(module), do: inspect(module)

  defp available_ethercat_drivers do
    Session.available_simulation_drivers()
    |> Enum.map(&format_module_name/1)
    |> Kernel.++(["EtherCAT.Driver.Default"])
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp driver_options(current_driver, recommended_driver, available_drivers) do
    [current_driver, recommended_driver | available_drivers]
    |> Enum.map(&to_string(&1 || ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp recommended_driver_for_row(slave_row, index, ethercat) do
    name = Map.get(slave_row, "name", "") |> String.trim()

    observed_slave =
      Enum.find(ethercat.slaves, &(to_string(&1.name) == name)) ||
        Enum.at(ethercat.slaves, index)

    case observed_slave && slave_driver(observed_slave) do
      nil -> nil
      "unknown" -> nil
      driver -> driver
    end
  end

  defp driver_recommendation_label(nil, _current_driver),
    do: "No observed identity recommendation yet."

  defp driver_recommendation_label(recommended_driver, current_driver) do
    current_driver = to_string(current_driver || "") |> String.trim()

    if current_driver == recommended_driver do
      "Matches observed identity."
    else
      "Recommended from observed identity: #{recommended_driver}"
    end
  end

  defp config_form_from_config(config) do
    config
    |> Session.ethercat_form_from_config()
    |> normalize_simulation_config_form()
  end

  defp workspace_runtime_input(socket) do
    current_form = normalize_simulation_config_form(socket.assigns.simulation_config_form)

    case SessionSync.current_hardware_config(socket) do
      %HardwareConfig{} = config ->
        if current_form == config_form_from_config(config) do
          config
        else
          current_form
        end

      _other ->
        current_form
    end
  end

  defp default_capture_config_form do
    %{"id" => "", "label" => ""}
  end

  defp normalize_capture_config_form(form) when is_map(form) do
    form
    |> Enum.reduce(default_capture_config_form(), fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value || ""))
    end)
  end

  defp normalize_capture_config_form(_form), do: default_capture_config_form()

  defp merge_simulation_config_form(current_form, params) when is_map(params) do
    current_form = normalize_simulation_config_form(current_form)
    raw_params = stringify_form_map_keys(params)

    domains =
      merge_simulation_domain_form_rows(
        Map.get(current_form, "domains", []),
        Map.get(raw_params, "domains")
      )

    domain_ids = normalized_domain_ids(domains)

    current_form
    |> Map.merge(Map.drop(raw_params, ["domains", "slaves"]))
    |> Map.put("domains", domains)
    |> Map.put(
      "slaves",
      merge_simulation_slave_form_rows(
        Map.get(current_form, "slaves", []),
        Map.get(raw_params, "slaves"),
        domain_ids
      )
    )
    |> normalize_simulation_config_form()
  end

  defp merge_simulation_config_form(current_form, _params) do
    normalize_simulation_config_form(current_form)
  end

  defp normalize_simulation_config_form(form) when is_map(form) do
    normalized_form =
      Enum.reduce(form, %{}, fn {key, value}, acc ->
        Map.put(acc, to_string(key), value)
      end)

    domains =
      case normalize_simulation_domain_rows(Map.get(normalized_form, "domains")) do
        [] -> [empty_simulation_domain_row()]
        rows -> rows
      end

    domain_ids = normalized_domain_ids(domains)

    slaves =
      case normalize_simulation_slave_rows(Map.get(normalized_form, "slaves"), domain_ids) do
        [] -> [empty_simulation_slave_row(domain_ids)]
        rows -> rows
      end

    normalized_form
    |> Map.put("domains", domains)
    |> Map.put("slaves", slaves)
  end

  defp normalize_simulation_config_form(_form) do
    Session.default_ethercat_simulation_form()
  end

  defp normalize_simulation_slave_rows(rows, domain_ids) when is_list(rows) do
    Enum.map(rows, &normalize_simulation_slave_row(&1, domain_ids))
  end

  defp normalize_simulation_slave_rows(rows, domain_ids) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} ->
      case Integer.parse(to_string(index)) do
        {int, ""} -> int
        _ -> 999_999
      end
    end)
    |> Enum.map(fn {_index, row} -> normalize_simulation_slave_row(row, domain_ids) end)
  end

  defp normalize_simulation_slave_rows(_rows, _domain_ids), do: []

  defp merge_simulation_slave_form_rows(current_rows, nil, domain_ids) do
    normalize_simulation_slave_rows(current_rows, domain_ids)
  end

  defp merge_simulation_slave_form_rows(current_rows, rows, domain_ids) do
    current_rows = normalize_simulation_slave_rows(current_rows, domain_ids)

    rows
    |> ordered_form_rows()
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      current_row = Enum.at(current_rows, index, empty_simulation_slave_row(domain_ids))
      Map.merge(current_row, stringify_form_map_keys(row))
    end)
  end

  defp normalize_simulation_domain_rows(rows) when is_list(rows) do
    Enum.map(rows, &normalize_simulation_domain_row/1)
  end

  defp normalize_simulation_domain_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} ->
      case Integer.parse(to_string(index)) do
        {int, ""} -> int
        _ -> 999_999
      end
    end)
    |> Enum.map(fn {_index, row} -> normalize_simulation_domain_row(row) end)
  end

  defp normalize_simulation_domain_rows(_rows), do: []

  defp merge_simulation_domain_form_rows(current_rows, nil) do
    normalize_simulation_domain_rows(current_rows)
  end

  defp merge_simulation_domain_form_rows(_current_rows, rows) do
    normalize_simulation_domain_rows(rows)
  end

  defp normalize_simulation_domain_row(row) when is_map(row) do
    row
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value || "")} end)
    |> Map.put_new("id", "")
    |> Map.put_new("cycle_time_us", "")
    |> Map.put_new("miss_threshold", "1000")
    |> Map.put_new("recovery_threshold", "3")
  end

  defp normalize_simulation_domain_row(_row), do: empty_simulation_domain_row()

  defp empty_simulation_domain_row do
    %{
      "id" => "",
      "cycle_time_us" => "",
      "miss_threshold" => "1000",
      "recovery_threshold" => "3"
    }
  end

  defp normalize_simulation_slave_row(row, domain_ids) when is_map(row) do
    default_domain_id = default_simulation_domain_id(domain_ids)
    row = Enum.into(row, %{}, fn {key, value} -> {to_string(key), to_string(value || "")} end)

    {process_data_mode, process_data_domain} =
      default_process_data_for_driver(Map.get(row, "driver", ""), default_domain_id)

    row
    |> Map.put_new("name", "")
    |> Map.put_new("driver", "")
    |> Map.put_new("target_state", "op")
    |> Map.put("process_data_mode", process_data_mode)
    |> Map.put(
      "process_data_domain",
      normalize_simulation_process_data_domain(process_data_domain, domain_ids)
    )
    |> Map.update("health_poll_ms", default_health_poll_field(), fn
      "" -> default_health_poll_field()
      value -> value
    end)
  end

  defp normalize_simulation_slave_row(_row, domain_ids),
    do: empty_simulation_slave_row(domain_ids)

  defp empty_simulation_slave_row(domain_ids \\ []) do
    default_domain_id = default_simulation_domain_id(domain_ids)

    {process_data_mode, process_data_domain} =
      default_process_data_for_driver("", default_domain_id)

    %{
      "name" => "",
      "driver" => "",
      "target_state" => "op",
      "process_data_mode" => process_data_mode,
      "process_data_domain" => process_data_domain,
      "health_poll_ms" => default_health_poll_field()
    }
  end

  defp ordered_form_rows(rows) when is_list(rows), do: rows

  defp ordered_form_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} ->
      case Integer.parse(to_string(index)) do
        {int, ""} -> int
        _ -> 999_999
      end
    end)
    |> Enum.map(fn {_index, row} -> row end)
  end

  defp ordered_form_rows(_rows), do: []

  defp remove_simulation_domain(domains, index) when is_binary(index) do
    case Integer.parse(index) do
      {int, ""} -> remove_simulation_domain(domains, int)
      _ -> domains
    end
  end

  defp remove_simulation_domain(domains, index) when is_integer(index) do
    domains
    |> List.delete_at(index)
    |> case do
      [] -> [empty_simulation_domain_row()]
      rows -> rows
    end
  end

  defp remove_simulation_slave(slaves, index) when is_binary(index) do
    case Integer.parse(index) do
      {int, ""} -> remove_simulation_slave(slaves, int)
      _ -> slaves
    end
  end

  defp remove_simulation_slave(slaves, index) when is_integer(index) do
    slaves
    |> List.delete_at(index)
    |> case do
      [] -> [empty_simulation_slave_row()]
      rows -> rows
    end
  end

  defp normalized_domain_ids(domains) do
    domains
    |> Enum.map(&Map.get(&1, "id", ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp default_simulation_domain_id([domain_id | _rest]), do: domain_id
  defp default_simulation_domain_id([]), do: ""

  defp normalize_simulation_process_data_domain(current, domain_ids) do
    trimmed = String.trim(to_string(current || ""))

    cond do
      domain_ids == [] -> ""
      trimmed == "" -> default_simulation_domain_id(domain_ids)
      trimmed in domain_ids -> trimmed
      true -> default_simulation_domain_id(domain_ids)
    end
  end

  defp default_health_poll_field do
    EtherCAT.Slave.Config.default_health_poll_ms()
    |> Integer.to_string()
  end

  defp default_process_data_for_driver(driver_name, default_domain_id) do
    driver =
      driver_name
      |> to_string()
      |> String.trim()
      |> case do
        "" -> nil
        trimmed -> Module.concat([String.trim_leading(trimmed, "Elixir.")])
      end

    if is_atom(driver) and Code.ensure_loaded?(driver) and
         function_exported?(driver, :signal_model, 2) do
      {"all", default_domain_id}
    else
      {"none", default_domain_id}
    end
  end

  defp stringify_form_map_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp running_simulation_config_id(
         _events,
         %{observed: %{source: :simulator}, commissioning: %{config_id: config_id}}
       )
       when is_binary(config_id),
       do: config_id

  defp running_simulation_config_id(events, %{observed: %{source: :simulator}}) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{type: :hardware_simulation_started, meta: %{config_id: config_id}}
      when is_binary(config_id) ->
        config_id

      %{type: :hardware_simulation_started, payload: %{config_id: config_id}}
      when is_binary(config_id) ->
        config_id

      _other ->
        nil
    end)
  end

  defp running_simulation_config_id(_events, _hardware_context), do: nil

  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)

  defp mismatch_panel(assigns) do
    ~H"""
    <div class="border border-white/8 bg-slate-900/70 px-3 py-3">
      <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">{@title}</p>
      <div class="mt-2 space-y-1 text-[12px] text-slate-200">
        <p :for={row <- @rows}>{row}</p>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, required: true)

  defp summary_panel(assigns) do
    ~H"""
    <div class="border border-white/8 bg-slate-900/75 px-3 py-3">
      <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">{@label}</p>
      <p class="mt-1 text-sm font-semibold text-slate-100">{@value}</p>
      <p class="mt-1 text-[11px] text-slate-500">{@detail}</p>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp mini_stat(assigns) do
    ~H"""
    <div class="border border-white/8 bg-slate-900/70 px-3 py-2.5">
      <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">{@label}</p>
      <p class="mt-1 text-sm font-semibold text-slate-100">{@value}</p>
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:body, :string, required: true)

  defp detail_panel(assigns) do
    ~H"""
    <div class="border border-white/8 bg-slate-900/70 px-3 py-2.5">
      <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">{@title}</p>
      <p class="mt-1 text-[12px] text-slate-200">{@body}</p>
    </div>
    """
  end
end
