defmodule OgolWeb.Studio.HardwareLive do
  use OgolWeb, :live_view

  alias Ogol.Hardware.EtherCAT, as: EtherCATHardware
  alias Ogol.Hardware.EtherCAT.Studio.Cell, as: EtherCATDriverCell
  alias Ogol.Hardware.Source, as: HardwareSource
  alias Ogol.Hardware.Studio.Cell, as: HardwareCell
  alias Ogol.Session
  alias Ogol.Studio.Build
  alias Ogol.Studio.Cell, as: StudioCellModel
  alias OgolWeb.Live.SessionAction
  alias OgolWeb.Live.SessionSync
  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Studio.Library, as: StudioLibrary

  @adapter_id "ethercat"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> SessionSync.attach()
     |> assign(:page_title, "Hardware Studio")
     |> assign(
       :page_summary,
       "Author the canonical EtherCAT hardware for the current workspace. Topology start will compile it and bring the master up from this source."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :hardware)
     |> assign(:hmi_subnav, :ethercat)
     |> assign(:adapter_id, nil)
     |> assign(:selected_driver_id, nil)
     |> assign(:requested_view, :config)
     |> assign(:hardware_draft, nil)
     |> assign(:hardware, nil)
     |> assign(:hardware_source, "")
     |> assign(:hardware_form, normalize_hardware_form(nil))
     |> assign(:current_source_digest, Build.digest(""))
     |> assign(:validation_errors, [])
     |> assign(:sync_state, :synced)
     |> assign(:sync_diagnostics, [])
     |> assign(:hardware_issue, nil)
     |> assign(:runtime_status, HardwareCell.default_runtime_status())
     |> assign(:available_ethercat_drivers, available_driver_options())
     |> assign(:available_raw_interfaces, Session.available_raw_interfaces())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    adapter_id =
      if socket.assigns.live_action in [:show, :cell, :driver_show, :driver_cell],
        do: params["adapter_id"],
        else: nil

    selected_driver_id =
      if driver_live_action?(socket.assigns.live_action), do: params["driver_id"], else: nil

    requested_view =
      if driver_live_action?(socket.assigns.live_action),
        do: :config,
        else: requested_view(params["view"])

    socket =
      socket
      |> maybe_ensure_adapter_config(adapter_id)
      |> SessionSync.refresh()
      |> assign(:adapter_id, adapter_id)
      |> assign(:selected_driver_id, selected_driver_id)
      |> assign(:requested_view, requested_view)
      |> assign(:hmi_subnav, if(adapter_id == @adapter_id, do: :ethercat, else: nil))
      |> load_page_state()

    {:noreply, maybe_canonicalize_path(socket, adapter_id, params["view"], selected_driver_id)}
  end

  @impl true
  def handle_info({:operations, operations}, socket) do
    hardware_issue =
      if Enum.all?(operations, &artifact_runtime_operation?/1) do
        socket.assigns[:hardware_issue]
      else
        nil
      end

    {:noreply,
     socket
     |> SessionSync.apply_operations(operations)
     |> load_page_state()
     |> assign(:hardware_issue, hardware_issue)}
  end

  @impl true
  def handle_event("select_view", %{"view" => raw_view}, socket) do
    {:noreply, push_patch(socket, to: current_path(socket.assigns.adapter_id, raw_view, socket))}
  end

  def handle_event("request_transition", %{"transition" => transition}, socket)
      when transition in ["compile", "recompile"] do
    control =
      if driver_live_action?(socket.assigns.live_action) do
        current_driver_control(socket.assigns, transition)
      else
        current_hardware_control(socket.assigns, transition)
      end

    case control do
      nil ->
        {:noreply, socket}

      control ->
        SessionAction.reduce_control(socket, control,
          after: &apply_runtime_feedback(&1, control.operation, &2)
        )
    end
  end

  def handle_event("change_visual", %{"hardware" => params}, socket) do
    form = merge_hardware_form(socket.assigns.hardware_form, params)
    {:noreply, persist_visual_form(socket, form)}
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    case HardwareSource.from_source(source) do
      {:ok, %EtherCATHardware{} = config} ->
        draft = Session.save_hardware_source(@adapter_id, source, config, :synced, [])

        {:noreply,
         socket
         |> assign(:hardware_draft, draft)
         |> assign(:hardware, config)
         |> assign(:hardware_source, source)
         |> assign(
           :hardware_form,
           normalize_hardware_form(Session.ethercat_hardware_form_from_config(config))
         )
         |> assign(:current_source_digest, Build.digest(source))
         |> assign(:validation_errors, [])
         |> assign(:sync_state, :synced)
         |> assign(:sync_diagnostics, [])
         |> assign(:hardware_issue, nil)
         |> assign(:runtime_status, current_runtime_status(socket, @adapter_id))}

      :unsupported ->
        diagnostics = [
          "Current source can no longer be represented by the EtherCAT hardware editor."
        ]

        draft =
          Session.save_hardware_source(@adapter_id, source, nil, :unsupported, diagnostics)

        {:noreply,
         socket
         |> assign(:hardware_draft, draft)
         |> assign(:hardware, nil)
         |> assign(:hardware_source, source)
         |> assign(:current_source_digest, Build.digest(source))
         |> assign(:sync_state, :unsupported)
         |> assign(:sync_diagnostics, diagnostics)
         |> assign(:validation_errors, [])
         |> assign(:hardware_issue, nil)
         |> assign(:runtime_status, current_runtime_status(socket, @adapter_id))}
    end
  end

  def handle_event("add_domain", _params, socket) do
    form =
      socket.assigns.hardware_form
      |> normalize_hardware_form()
      |> update_in(["domains"], &(&1 ++ [empty_domain_row()]))

    {:noreply, persist_visual_form(socket, form)}
  end

  def handle_event("remove_domain", %{"index" => index}, socket) do
    form =
      socket.assigns.hardware_form
      |> normalize_hardware_form()
      |> update_in(["domains"], &remove_row(&1, index, empty_domain_row()))

    {:noreply, persist_visual_form(socket, form)}
  end

  def handle_event("add_slave", _params, socket) do
    form =
      socket.assigns.hardware_form
      |> normalize_hardware_form()
      |> then(fn form ->
        update_in(form["slaves"], &(&1 ++ [empty_slave_row(domain_ids(form["domains"]))]))
      end)

    {:noreply, persist_visual_form(socket, form)}
  end

  def handle_event("remove_slave", %{"index" => index}, socket) do
    form =
      socket.assigns.hardware_form
      |> normalize_hardware_form()
      |> then(fn form ->
        update_in(
          form["slaves"],
          &remove_row(&1, index, empty_slave_row(domain_ids(form["domains"])))
        )
      end)

    {:noreply, persist_visual_form(socket, form)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:hardware_cell, current_hardware_cell(assigns))
      |> assign(:driver_cell, current_driver_cell(assigns))
      |> assign(
        :selected_driver_entry,
        selected_driver_entry(assigns.hardware_form["slaves"], assigns.selected_driver_id)
      )
      |> assign(
        :hardware_items,
        hardware_items(
          if(assigns.live_action in [:show, :driver_show], do: assigns.adapter_id, else: nil),
          assigns.hardware_draft
        )
      )

    ~H"""
    <%= if @live_action in [:cell, :driver_cell] do %>
      <.hardware_cell_body
        :if={not is_nil(@hardware_draft) and @live_action == :cell}
        hardware_cell={@hardware_cell}
        hardware_form={@hardware_form}
        hardware_source={@hardware_source}
        available_ethercat_drivers={@available_ethercat_drivers}
        available_raw_interfaces={@available_raw_interfaces}
        adapter_id={@adapter_id}
        live_action={@live_action}
      />

      <.driver_cell_body
        :if={not is_nil(@hardware_draft) and @live_action == :driver_cell}
        selected_driver_entry={@selected_driver_entry}
        hardware_form={@hardware_form}
        available_ethercat_drivers={@available_ethercat_drivers}
        adapter_id={@adapter_id}
        live_action={@live_action}
      />

      <section :if={!@hardware_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Hardware</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          EtherCAT is not configured in the current workspace
        </h2>
      </section>
    <% else %>
      <%= if @live_action in [:show, :driver_show] do %>
        <section class="grid gap-5">
          <.hardware_cell_panel
            hardware_draft={@hardware_draft}
            hardware_cell={@hardware_cell}
            hardware_form={@hardware_form}
            hardware_source={@hardware_source}
            available_ethercat_drivers={@available_ethercat_drivers}
            available_raw_interfaces={@available_raw_interfaces}
            adapter_id={@adapter_id}
            live_action={@live_action}
          />

          <.driver_cell_panel
            hardware_draft={@hardware_draft}
            driver_cell={@driver_cell}
            hardware_form={@hardware_form}
            selected_driver_entry={@selected_driver_entry}
            available_ethercat_drivers={@available_ethercat_drivers}
            adapter_id={@adapter_id}
            live_action={@live_action}
          />
        </section>
      <% else %>
        <section class="grid gap-5">
          <StudioLibrary.list title="Hardware" items={@hardware_items} current_id={nil} />
        </section>
      <% end %>
    <% end %>
    """
  end

  attr(:hardware_draft, :any, required: true)
  attr(:hardware_cell, :map, default: nil)
  attr(:hardware_form, :map, required: true)
  attr(:hardware_source, :string, default: "")
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:available_raw_interfaces, :list, default: [])
  attr(:adapter_id, :string, default: nil)
  attr(:live_action, :atom, required: true)

  defp hardware_cell_panel(assigns) do
    ~H"""
    <StudioCell.cell :if={@hardware_draft} body_class="min-h-[60rem]">
      <:actions>
        <StudioCell.action_button
          :for={control <- @hardware_cell.controls}
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

      <:notice :if={@hardware_cell.notice}>
        <StudioCell.notice
          tone={@hardware_cell.notice.tone}
          title={@hardware_cell.notice.title}
          message={@hardware_cell.notice.message}
        />
      </:notice>

      <:views>
        <StudioCell.view_button
          :for={view <- @hardware_cell.views}
          type="button"
          phx-click="select_view"
          phx-value-view={view.id}
          selected={@hardware_cell.selected_view == view.id}
          available={view.available?}
          data-test={"hardware-view-#{view.id}"}
        >
          {view.label}
        </StudioCell.view_button>
      </:views>

      <:body>
        <.hardware_cell_body
          hardware_cell={@hardware_cell}
          hardware_form={@hardware_form}
          hardware_source={@hardware_source}
          available_ethercat_drivers={@available_ethercat_drivers}
          available_raw_interfaces={@available_raw_interfaces}
          adapter_id={@adapter_id}
          live_action={@live_action}
        />
      </:body>
    </StudioCell.cell>

    <section :if={!@hardware_draft} class="app-panel px-5 py-5">
      <p class="app-kicker">No Hardware</p>
      <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
        EtherCAT is not configured in the current workspace
      </h2>
    </section>
    """
  end

  attr(:hardware_cell, :map, required: true)
  attr(:hardware_form, :map, required: true)
  attr(:hardware_source, :string, default: "")
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:available_raw_interfaces, :list, default: [])
  attr(:adapter_id, :string, default: nil)
  attr(:live_action, :atom, required: true)

  defp hardware_cell_body(assigns) do
    ~H"""
    <.config_editor
      :if={@hardware_cell.selected_view == :config}
      hardware_form={@hardware_form}
      available_ethercat_drivers={@available_ethercat_drivers}
      available_raw_interfaces={@available_raw_interfaces}
    />

    <.source_editor
      :if={@hardware_cell.selected_view == :source}
      hardware_source={@hardware_source}
    />
    """
  end

  attr(:hardware_form, :map, required: true)
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:available_raw_interfaces, :list, default: [])

  defp config_editor(assigns) do
    domain_ids = domain_ids(assigns.hardware_form["domains"])
    assigns = assign(assigns, :domain_ids, domain_ids)

    ~H"""
    <section class="app-panel px-5 py-5" data-test="hardware-config-form">
      <form phx-change="change_visual" class="space-y-8">
        <section class="grid gap-4 md:grid-cols-2">
          <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
            <span class="font-medium text-[var(--app-text)]">Config Id</span>
            <input
              name="hardware[id]"
              value={Map.get(@hardware_form, "id", "")}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
            <span class="font-medium text-[var(--app-text)]">Label</span>
            <input
              name="hardware[label]"
              value={Map.get(@hardware_form, "label", "")}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
            <span class="font-medium text-[var(--app-text)]">Transport</span>
            <select name="hardware[transport]" class="app-input w-full">
              <option value="udp" selected={Map.get(@hardware_form, "transport") == "udp"}>UDP</option>
              <option value="raw" selected={Map.get(@hardware_form, "transport") == "raw"}>Raw</option>
              <option value="redundant" selected={Map.get(@hardware_form, "transport") == "redundant"}>
                Redundant
              </option>
            </select>
          </label>

          <label
            :if={udp_transport?(@hardware_form)}
            class="space-y-2 text-sm text-[var(--app-text-muted)]"
          >
            <span class="font-medium text-[var(--app-text)]">Bind IP</span>
            <input
              name="hardware[bind_ip]"
              value={Map.get(@hardware_form, "bind_ip", "")}
              class="app-input w-full"
            />
          </label>

          <.interface_field
            :if={uses_primary_interface?(@hardware_form)}
            label="Primary Interface"
            name="hardware[primary_interface]"
            value={Map.get(@hardware_form, "primary_interface", "")}
            options={@available_raw_interfaces}
          />

          <.interface_field
            :if={redundant_transport?(@hardware_form)}
            label="Secondary Interface"
            name="hardware[secondary_interface]"
            value={Map.get(@hardware_form, "secondary_interface", "")}
            options={@available_raw_interfaces}
          />

          <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
            <span class="font-medium text-[var(--app-text)]">Scan Stable (ms)</span>
            <input
              name="hardware[scan_stable_ms]"
              value={Map.get(@hardware_form, "scan_stable_ms", "")}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
            <span class="font-medium text-[var(--app-text)]">Scan Poll (ms)</span>
            <input
              name="hardware[scan_poll_ms]"
              value={Map.get(@hardware_form, "scan_poll_ms", "")}
              class="app-input w-full"
            />
          </label>

          <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
            <span class="font-medium text-[var(--app-text)]">Frame Timeout (ms)</span>
            <input
              name="hardware[frame_timeout_ms]"
              value={Map.get(@hardware_form, "frame_timeout_ms", "")}
              class="app-input w-full"
            />
          </label>
        </section>

        <section class="space-y-4">
          <div class="flex items-center justify-between gap-4">
            <div>
              <h3 class="text-lg font-semibold text-[var(--app-text)]">Domains</h3>
              <p class="text-sm text-[var(--app-text-muted)]">
                Scheduling domains and their cycle timing.
              </p>
            </div>

            <button type="button" phx-click="add_domain" class="app-button-secondary">Add Domain</button>
          </div>

          <div class="grid gap-4">
            <section
              :for={{domain, index} <- Enum.with_index(@hardware_form["domains"])}
              class="app-panel px-4 py-4"
              data-test={"hardware-domain-#{index}"}
            >
              <div class="grid gap-4 md:grid-cols-4">
                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Id</span>
                  <input
                    name={"hardware[domains][#{index}][id]"}
                    value={Map.get(domain, "id", "")}
                    class="app-input w-full"
                  />
                </label>

                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Cycle Time (us)</span>
                  <input
                    name={"hardware[domains][#{index}][cycle_time_us]"}
                    value={Map.get(domain, "cycle_time_us", "")}
                    class="app-input w-full"
                  />
                </label>

                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Miss Threshold</span>
                  <input
                    name={"hardware[domains][#{index}][miss_threshold]"}
                    value={Map.get(domain, "miss_threshold", "")}
                    class="app-input w-full"
                  />
                </label>

                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Recovery Threshold</span>
                  <input
                    name={"hardware[domains][#{index}][recovery_threshold]"}
                    value={Map.get(domain, "recovery_threshold", "")}
                    class="app-input w-full"
                  />
                </label>
              </div>

              <div class="mt-3 flex justify-end">
                <button
                  type="button"
                  phx-click="remove_domain"
                  phx-value-index={index}
                  class="app-button-secondary"
                >
                  Remove
                </button>
              </div>
            </section>
          </div>
        </section>

        <section class="space-y-4">
          <div class="flex items-center justify-between gap-4">
            <div>
              <h3 class="text-lg font-semibold text-[var(--app-text)]">Slaves</h3>
              <p class="text-sm text-[var(--app-text-muted)]">
                Ring members, runtime targets, and process data participation.
              </p>
            </div>

            <button type="button" phx-click="add_slave" class="app-button-secondary">Add Slave</button>
          </div>

          <div class="grid gap-4">
            <section
              :for={{slave, index} <- Enum.with_index(@hardware_form["slaves"])}
              class="app-panel px-4 py-4"
              data-test={"hardware-slave-#{index}"}
            >
              <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-3">
                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Name</span>
                  <input
                    name={"hardware[slaves][#{index}][name]"}
                    value={Map.get(slave, "name", "")}
                    class="app-input w-full"
                  />
                </label>

                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Driver</span>
                  <select
                    name={"hardware[slaves][#{index}][driver]"}
                    class="app-input w-full"
                  >
                    <option :for={driver <- @available_ethercat_drivers} value={driver} selected={Map.get(slave, "driver") == driver}>
                      {driver}
                    </option>
                  </select>
                </label>

                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Target State</span>
                  <select
                    name={"hardware[slaves][#{index}][target_state]"}
                    class="app-input w-full"
                  >
                    <option value="op" selected={Map.get(slave, "target_state") == "op"}>Operational</option>
                    <option value="preop" selected={Map.get(slave, "target_state") == "preop"}>Pre-Operational</option>
                  </select>
                </label>

                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Process Data</span>
                  <select
                    name={"hardware[slaves][#{index}][process_data_mode]"}
                    class="app-input w-full"
                  >
                    <option value="none" selected={Map.get(slave, "process_data_mode") == "none"}>None</option>
                    <option value="all" selected={Map.get(slave, "process_data_mode") == "all"}>All Signals</option>
                  </select>
                </label>

                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Domain</span>
                  <select
                    name={"hardware[slaves][#{index}][process_data_domain]"}
                    class="app-input w-full"
                  >
                    <option :for={domain_id <- @domain_ids} value={domain_id} selected={Map.get(slave, "process_data_domain") == domain_id}>
                      {domain_id}
                    </option>
                  </select>
                </label>

                <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                  <span class="font-medium text-[var(--app-text)]">Health Poll (ms)</span>
                  <input
                    name={"hardware[slaves][#{index}][health_poll_ms]"}
                    value={Map.get(slave, "health_poll_ms", "")}
                    class="app-input w-full"
                  />
                </label>
              </div>

              <div class="mt-3 flex justify-end">
                <button
                  type="button"
                  phx-click="remove_slave"
                  phx-value-index={index}
                  class="app-button-secondary"
                >
                  Remove
                </button>
              </div>
            </section>
          </div>
        </section>
      </form>
    </section>
    """
  end

  attr(:hardware_draft, :any, required: true)
  attr(:driver_cell, :map, default: nil)
  attr(:hardware_form, :map, required: true)
  attr(:selected_driver_entry, :any, default: nil)
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:adapter_id, :string, default: nil)
  attr(:live_action, :atom, required: true)

  defp driver_cell_panel(assigns) do
    ~H"""
    <StudioCell.cell :if={@hardware_draft} body_class="min-h-[40rem]">
      <:actions>
        <StudioCell.action_button
          :for={control <- @driver_cell.controls}
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

      <:notice :if={@driver_cell.notice}>
        <StudioCell.notice
          tone={@driver_cell.notice.tone}
          title={@driver_cell.notice.title}
          message={@driver_cell.notice.message}
        />
      </:notice>

      <:body>
        <.driver_cell_body
          selected_driver_entry={@selected_driver_entry}
          hardware_form={@hardware_form}
          available_ethercat_drivers={@available_ethercat_drivers}
          adapter_id={@adapter_id}
          live_action={@live_action}
        />
      </:body>
    </StudioCell.cell>
    """
  end

  attr(:selected_driver_entry, :any, default: nil)
  attr(:hardware_form, :map, required: true)
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:adapter_id, :string, default: nil)
  attr(:live_action, :atom, required: true)

  defp driver_cell_body(assigns) do
    assigns =
      assigns
      |> assign(
        :driver_items,
        driver_items(assigns.hardware_form["slaves"], assigns.adapter_id, assigns.live_action)
      )
      |> assign(
        :selected_driver_id,
        if(assigns.selected_driver_entry,
          do: driver_entry_id(assigns.selected_driver_entry),
          else: nil
        )
      )

    ~H"""
    <section :if={@driver_items == []} class="app-panel px-5 py-5">
      <p class="app-kicker">No Drivers</p>
      <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
        EtherCAT hardware does not define any slave drivers yet.
      </h2>
    </section>

    <section :if={@driver_items != []} class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
      <div data-test="ethercat-driver-library">
        <StudioLibrary.list
          title="Drivers"
          items={@driver_items}
          current_id={@selected_driver_id}
          empty_label="No drivers defined yet."
        />
      </div>

      <section class="grid gap-4">
        <div :if={is_nil(@selected_driver_entry)} class="app-panel px-5 py-5">
          <p class="app-kicker">EtherCAT Drivers</p>
          <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
            Defined slave drivers
          </h2>
          <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
            Select a driver from the list to focus it, or edit the current driver set below and recompile the enclosing EtherCAT hardware artifact.
          </p>
        </div>

        <div :if={!is_nil(@selected_driver_entry)} class="flex items-center justify-between gap-3 app-panel px-5 py-4">
          <div>
            <p class="app-kicker">EtherCAT Driver</p>
            <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
              {humanize_slave_title(driver_entry_id(@selected_driver_entry))}
            </h2>
          </div>

          <.link
            patch={driver_overview_path(@adapter_id, @live_action)}
            class="app-button-secondary"
          >
            Back To Drivers
          </.link>
        </div>

        <.driver_editor
          hardware_form={@hardware_form}
          available_ethercat_drivers={@available_ethercat_drivers}
          adapter_id={@adapter_id}
          live_action={@live_action}
          selected_driver_id={@selected_driver_id}
        />
      </section>
    </section>
    """
  end

  attr(:hardware_form, :map, required: true)
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:adapter_id, :string, default: nil)
  attr(:live_action, :atom, required: true)
  attr(:selected_driver_id, :string, default: nil)

  defp driver_editor(assigns) do
    assigns =
      assign(
        assigns,
        :driver_rows,
        driver_rows(assigns.hardware_form["slaves"], assigns.selected_driver_id)
      )

    ~H"""
    <section class="grid gap-4" data-test="hardware-driver-form">
      <section
        :for={{slave, index} <- @driver_rows}
        class="app-panel px-5 py-5"
        data-test={"hardware-driver-#{index}"}
      >
        <form phx-change="change_visual" class="space-y-4">
          <div class="flex flex-col gap-2 lg:flex-row lg:items-start lg:justify-between">
            <div>
              <p class="app-kicker">Slave Driver</p>
              <h3 class="mt-2 text-xl font-semibold tracking-tight text-[var(--app-text)]">
                {humanize_slave_title(Map.get(slave, "name", "slave_#{index + 1}"))}
              </h3>
              <p class="mt-2 text-sm leading-6 text-[var(--app-text-muted)]">
                {driver_description(Map.get(slave, "driver", ""))}
              </p>
            </div>

            <div class="flex flex-col gap-3 lg:min-w-[22rem]">
              <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                <span class="font-medium text-[var(--app-text)]">Driver Module</span>
                <select name={"hardware[slaves][#{index}][driver]"} class="app-input w-full">
                  <option :for={driver <- @available_ethercat_drivers} value={driver} selected={Map.get(slave, "driver") == driver}>
                    {driver}
                  </option>
                </select>
              </label>

              <.link
                :if={show_driver_link?(@selected_driver_id, slave)}
                patch={driver_path(@adapter_id, driver_entry_id({slave, index}), @live_action)}
                class="app-button-secondary"
                data-test={"hardware-driver-cell-link-#{index}"}
              >
                Open Driver Cell
              </.link>
            </div>
          </div>

          <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
            <section class="app-panel px-4 py-4">
              <p class="app-kicker">Identity</p>
              <div class="mt-3 grid gap-2 text-sm text-[var(--app-text-muted)]">
                <p>Signals: {driver_signals_text(Map.get(slave, "driver", ""))}</p>
                <p>Mode: {driver_process_mode_text(slave)}</p>
                <p>Target State: {Map.get(slave, "target_state", "op")}</p>
              </div>
            </section>

            <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
              <span class="font-medium text-[var(--app-text)]">Canonical Signals</span>
              <div class="app-input min-h-[14rem] w-full bg-[var(--app-panel)] p-4 font-mono text-sm">
                {driver_signals_text(Map.get(slave, "driver", ""))}
              </div>
              <span class="text-xs text-[var(--app-text-dim)]">
                Topology wiring uses these canonical EtherCAT signal names directly.
              </span>
            </label>
          </div>
        </form>
      </section>
    </section>
    """
  end

  attr(:hardware_source, :string, default: "")

  defp source_editor(assigns) do
    ~H"""
    <section class="app-panel px-5 py-5" data-test="hardware-config-source">
      <form phx-change="change_source">
        <textarea
          name="draft[source]"
          class="min-h-[36rem] w-full rounded-md border border-[var(--app-border)] bg-[var(--app-canvas)] p-4 font-mono text-sm text-[var(--app-text)]"
        ><%= @hardware_source %></textarea>
      </form>
    </section>
    """
  end

  defp load_page_state(%{assigns: %{live_action: :index}} = socket), do: socket

  defp load_page_state(socket) do
    draft = SessionSync.fetch_hardware(socket, :ethercat)
    config = SessionSync.hardware_model(socket, :ethercat)
    source = draft_source(draft, config)

    socket
    |> assign(:hardware_draft, draft)
    |> assign(:hardware, config)
    |> assign(:hardware_source, source)
    |> assign(:hardware_form, draft_form(draft, config))
    |> assign(:current_source_digest, Build.digest(source))
    |> assign(:sync_state, if(draft, do: draft.sync_state, else: :synced))
    |> assign(:sync_diagnostics, if(draft, do: List.wrap(draft.sync_diagnostics), else: []))
    |> assign(:validation_errors, [])
    |> assign(:runtime_status, current_runtime_status(socket, @adapter_id))
  end

  defp current_runtime_status(source, adapter_id) when is_binary(adapter_id) do
    SessionSync.runtime_artifact_status(source, :hardware, adapter_id) ||
      HardwareCell.default_runtime_status()
  end

  defp current_hardware_cell(%{hardware_draft: nil}), do: nil

  defp current_hardware_cell(assigns) do
    assigns
    |> HardwareCell.facts_from_assigns()
    |> then(&StudioCellModel.derive(HardwareCell, &1))
  end

  defp current_driver_cell(%{hardware_draft: nil}), do: nil

  defp current_driver_cell(assigns) do
    assigns
    |> EtherCATDriverCell.facts_from_assigns()
    |> then(&StudioCellModel.derive(EtherCATDriverCell, &1))
  end

  defp current_driver_control(assigns, transition) do
    assigns
    |> current_driver_cell()
    |> StudioCellModel.control_for_transition(transition)
  end

  defp current_hardware_control(assigns, transition) do
    assigns
    |> current_hardware_cell()
    |> StudioCellModel.control_for_transition(transition)
  end

  defp artifact_runtime_operation?({:replace_artifact_runtime, statuses}) when is_list(statuses),
    do: true

  defp artifact_runtime_operation?(_operation), do: false

  defp apply_runtime_feedback(
         socket,
         {:compile_artifact, :hardware, @adapter_id},
         {:error, :module_not_found}
       ) do
    assign(
      socket,
      :hardware_issue,
      {:compile_missing_module, "Source must define one EtherCAT hardware module before compile."}
    )
  end

  defp apply_runtime_feedback(
         socket,
         {:compile_artifact, :hardware, @adapter_id},
         _reply
       ) do
    assign(socket, :hardware_issue, nil)
  end

  defp apply_runtime_feedback(socket, _action, _reply), do: socket

  defp maybe_ensure_adapter_config(socket, @adapter_id) do
    case SessionSync.fetch_hardware(socket, :ethercat) do
      nil ->
        _draft = Session.create_hardware(:ethercat)
        socket

      _draft ->
        socket
    end
  end

  defp maybe_ensure_adapter_config(socket, _adapter_id), do: socket

  defp persist_visual_form(socket, form) do
    case Session.preview_ethercat_hardware_form(form) do
      {:ok, %EtherCATHardware{} = config} ->
        source = HardwareSource.to_source(config)
        draft = Session.save_hardware_source(@adapter_id, source, config, :synced, [])

        socket
        |> assign(:hardware_draft, draft)
        |> assign(:hardware, config)
        |> assign(:hardware_source, source)
        |> assign(:hardware_form, form)
        |> assign(:current_source_digest, Build.digest(source))
        |> assign(:validation_errors, [])
        |> assign(:sync_state, :synced)
        |> assign(:sync_diagnostics, [])
        |> assign(:hardware_issue, nil)
        |> assign(:runtime_status, current_runtime_status(socket, @adapter_id))

      {:error, reason} ->
        socket
        |> assign(:hardware_form, form)
        |> assign(:validation_errors, [inspect(reason)])
    end
  end

  defp draft_source(%{source: source}, _config) when is_binary(source), do: source

  defp draft_source(_draft, %EtherCATHardware{} = config),
    do: HardwareSource.to_source(config)

  defp draft_source(_draft, _config), do: HardwareSource.default_source(:ethercat)

  defp draft_form(_draft, %EtherCATHardware{} = config) do
    config
    |> Session.ethercat_hardware_form_from_config()
    |> normalize_hardware_form()
  end

  defp draft_form(%{model: %EtherCATHardware{} = config}, _other), do: draft_form(nil, config)
  defp draft_form(_draft, _config), do: normalize_hardware_form(nil)

  defp merge_hardware_form(current_form, params) do
    current_form
    |> normalize_hardware_form()
    |> deep_merge_maps(Enum.into(params, %{}, fn {key, value} -> {to_string(key), value} end))
    |> normalize_hardware_form()
  end

  defp deep_merge_maps(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      deep_merge_form_value(left_value, right_value)
    end)
  end

  defp deep_merge_form_value(left, right) when is_map(left) and is_map(right) do
    deep_merge_maps(left, right)
  end

  defp deep_merge_form_value(left, right) when is_list(left) and is_map(right) do
    indexed_left =
      left
      |> Enum.with_index()
      |> Map.new(fn {value, index} -> {Integer.to_string(index), value} end)

    indexed_right =
      Enum.into(right, %{}, fn {key, value} -> {to_string(key), value} end)

    deep_merge_maps(indexed_left, indexed_right)
  end

  defp deep_merge_form_value(_left, right), do: right

  defp normalize_hardware_form(form) when is_map(form) do
    form
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("id", "ethercat_demo")
    |> Map.put_new("label", "EtherCAT")
    |> Map.put_new("transport", "udp")
    |> Map.put_new("bind_ip", "127.0.0.1")
    |> Map.put_new("primary_interface", "")
    |> Map.put_new("secondary_interface", "")
    |> Map.put_new("scan_stable_ms", "20")
    |> Map.put_new("scan_poll_ms", "10")
    |> Map.put_new("frame_timeout_ms", "20")
    |> normalize_domain_rows()
    |> normalize_slave_rows()
  end

  defp normalize_hardware_form(_form) do
    Session.default_ethercat_hardware_form()
    |> normalize_hardware_form()
  end

  defp normalize_domain_rows(form) do
    domains =
      case Map.get(form, "domains") do
        rows when is_map(rows) ->
          rows
          |> Enum.sort_by(fn {index, _row} -> parse_index(index) end)
          |> Enum.map(fn {_index, row} -> normalize_domain_row(row) end)

        rows when is_list(rows) ->
          Enum.map(rows, &normalize_domain_row/1)

        _other ->
          [empty_domain_row()]
      end

    Map.put(form, "domains", if(domains == [], do: [empty_domain_row()], else: domains))
  end

  defp normalize_slave_rows(form) do
    domains = domain_ids(form["domains"])

    slaves =
      case Map.get(form, "slaves") do
        rows when is_map(rows) ->
          rows
          |> Enum.sort_by(fn {index, _row} -> parse_index(index) end)
          |> Enum.map(fn {_index, row} -> normalize_slave_row(row, domains) end)

        rows when is_list(rows) ->
          Enum.map(rows, &normalize_slave_row(&1, domains))

        _other ->
          [empty_slave_row(domains)]
      end

    Map.put(form, "slaves", if(slaves == [], do: [empty_slave_row(domains)], else: slaves))
  end

  defp normalize_domain_row(row) when is_map(row) do
    row
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value || "")} end)
    |> Map.put_new("id", "")
    |> Map.put_new("cycle_time_us", "")
    |> Map.put_new("miss_threshold", "1000")
    |> Map.put_new("recovery_threshold", "3")
  end

  defp normalize_domain_row(_row), do: empty_domain_row()

  defp empty_domain_row do
    %{
      "id" => "",
      "cycle_time_us" => "",
      "miss_threshold" => "1000",
      "recovery_threshold" => "3"
    }
  end

  defp normalize_slave_row(row, domain_ids) when is_map(row) do
    row
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value || "")} end)
    |> Map.put_new("name", "")
    |> Map.put_new("driver", hd(available_driver_options()))
    |> Map.put_new("target_state", "op")
    |> Map.put_new("process_data_mode", "none")
    |> Map.put_new("process_data_domain", default_domain_id(domain_ids))
    |> Map.put_new("health_poll_ms", default_health_poll_ms())
    |> Map.update("process_data_domain", default_domain_id(domain_ids), fn current ->
      normalized = to_string(current || "")

      if normalized in domain_ids or domain_ids == [] do
        normalized
      else
        default_domain_id(domain_ids)
      end
    end)
  end

  defp normalize_slave_row(_row, domain_ids), do: empty_slave_row(domain_ids)

  defp empty_slave_row(domain_ids) do
    %{
      "name" => "",
      "driver" => hd(available_driver_options()),
      "target_state" => "op",
      "process_data_mode" => "none",
      "process_data_domain" => default_domain_id(domain_ids),
      "health_poll_ms" => default_health_poll_ms()
    }
  end

  defp available_driver_options do
    Session.available_simulation_drivers()
    |> Enum.map(fn module ->
      module
      |> inspect()
      |> String.trim_leading("Elixir.")
    end)
    |> Enum.sort()
  end

  defp domain_ids(domains) when is_list(domains) do
    domains
    |> Enum.map(&Map.get(&1, "id", ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp domain_ids(_domains), do: []

  attr(:label, :string, required: true)
  attr(:name, :string, required: true)
  attr(:value, :string, default: "")
  attr(:options, :list, default: [])

  defp interface_field(assigns) do
    ~H"""
    <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
      <span class="font-medium text-[var(--app-text)]">{@label}</span>

      <%= if @options == [] do %>
        <input name={@name} value={@value} class="app-input w-full" />
      <% else %>
        <select name={@name} class="app-input w-full">
          <option value="">Select interface</option>
          <option :for={interface <- @options} value={interface} selected={@value == interface}>
            {interface}
          </option>
        </select>
      <% end %>
    </label>
    """
  end

  defp udp_transport?(%{"transport" => "udp"}), do: true
  defp udp_transport?(_form), do: false

  defp raw_transport?(%{"transport" => "raw"}), do: true
  defp raw_transport?(_form), do: false

  defp redundant_transport?(%{"transport" => "redundant"}), do: true
  defp redundant_transport?(_form), do: false

  defp uses_primary_interface?(form), do: raw_transport?(form) or redundant_transport?(form)

  defp default_domain_id([domain_id | _rest]), do: domain_id
  defp default_domain_id([]), do: ""

  defp default_health_poll_ms do
    EtherCAT.Slave.Config.default_health_poll_ms()
    |> Integer.to_string()
  end

  defp remove_row(rows, index, fallback) when is_list(rows) do
    parsed_index = parse_index(index)

    rows
    |> Enum.with_index()
    |> Enum.reject(fn {_row, row_index} -> row_index == parsed_index end)
    |> Enum.map(&elem(&1, 0))
    |> case do
      [] -> [fallback]
      remaining -> remaining
    end
  end

  defp parse_index(index) do
    case Integer.parse(to_string(index)) do
      {value, ""} -> value
      _ -> -1
    end
  end

  defp requested_view(nil), do: :config
  defp requested_view(""), do: :config
  defp requested_view("config"), do: :config
  defp requested_view("drivers"), do: :config
  defp requested_view("source"), do: :source
  defp requested_view(_other), do: :config

  defp maybe_canonicalize_path(
         socket,
         _requested_adapter_id,
         _requested_view,
         _requested_driver_id
       )
       when socket.assigns.live_action not in [:show, :cell, :driver_show, :driver_cell],
       do: socket

  defp maybe_canonicalize_path(
         %{assigns: %{hardware_draft: nil}} = socket,
         _requested_id,
         _view,
         _driver_id
       ),
       do: socket

  defp maybe_canonicalize_path(socket, requested_adapter_id, _requested_view, requested_driver_id)
       when socket.assigns.live_action in [:driver_show, :driver_cell] do
    current_adapter_id = socket.assigns.adapter_id || @adapter_id

    driver_entry =
      selected_driver_entry(
        socket.assigns.hardware_form["slaves"],
        socket.assigns.selected_driver_id
      )

    canonical_path =
      case {socket.assigns.live_action, driver_entry} do
        {:driver_cell, nil} ->
          cell_path(current_adapter_id, :config)

        {:driver_show, nil} ->
          page_path(current_adapter_id, :config)

        {:driver_cell, entry} ->
          driver_cell_path(current_adapter_id, driver_entry_id(entry))

        {:driver_show, entry} ->
          driver_page_path(current_adapter_id, driver_entry_id(entry))
      end

    expected_driver_id = driver_entry && driver_entry_id(driver_entry)

    if current_adapter_id == requested_adapter_id and expected_driver_id == requested_driver_id do
      socket
    else
      push_patch(socket, to: canonical_path)
    end
  end

  defp maybe_canonicalize_path(socket, requested_adapter_id, requested_view, _requested_driver_id) do
    selected_view = current_hardware_cell(socket.assigns).selected_view
    current_adapter_id = socket.assigns.adapter_id || @adapter_id

    canonical_path =
      case socket.assigns.live_action do
        :cell -> cell_path(current_adapter_id, selected_view)
        _other -> page_path(current_adapter_id, selected_view)
      end

    if current_adapter_id == requested_adapter_id and
         (is_nil(requested_view) or requested_view == Atom.to_string(selected_view)) do
      socket
    else
      push_patch(socket, to: canonical_path)
    end
  end

  defp current_path(adapter_id, view, %{assigns: %{live_action: :cell}}) do
    cell_path(adapter_id || @adapter_id, view)
  end

  defp current_path(adapter_id, view, _socket) do
    page_path(adapter_id || @adapter_id, view)
  end

  defp page_path(adapter_id, :config), do: "/studio/hardware/#{adapter_id}"
  defp page_path(adapter_id, :source), do: "/studio/hardware/#{adapter_id}/source"

  defp page_path(adapter_id, view) when is_binary(view),
    do: page_path(adapter_id, requested_view(view))

  defp cell_path(adapter_id, :config), do: "/studio/cells/hardware/#{adapter_id}"
  defp cell_path(adapter_id, :source), do: "/studio/cells/hardware/#{adapter_id}/source"

  defp cell_path(adapter_id, view) when is_binary(view),
    do: cell_path(adapter_id, requested_view(view))

  defp driver_page_path(adapter_id, driver_id),
    do: "/studio/hardware/#{adapter_id}/drivers/#{driver_id}"

  defp driver_cell_path(adapter_id, driver_id),
    do: "/studio/cells/hardware/#{adapter_id}/drivers/#{driver_id}"

  defp driver_path(adapter_id, driver_id, live_action) when live_action in [:cell, :driver_cell],
    do: driver_cell_path(adapter_id, driver_id)

  defp driver_path(adapter_id, driver_id, _live_action),
    do: driver_page_path(adapter_id, driver_id)

  defp driver_overview_path(adapter_id, live_action) when live_action in [:cell, :driver_cell],
    do: cell_path(adapter_id, :config)

  defp driver_overview_path(adapter_id, _live_action), do: page_path(adapter_id, :config)

  defp hardware_items(current_id, draft) do
    [
      %{
        id: @adapter_id,
        label: "EtherCAT",
        detail: hardware_detail(draft),
        path: page_path(@adapter_id, :config),
        status: if(current_id == @adapter_id, do: "open", else: hardware_status_label(draft))
      }
    ]
  end

  defp hardware_detail(%{model: %EtherCATHardware{slaves: slaves}}),
    do: "#{length(slaves)} slave(s)"

  defp hardware_detail(_draft), do: "Canonical workspace hardware"

  defp hardware_status_label(%{sync_state: :unsupported}), do: "Source-only"
  defp hardware_status_label(%{sync_state: :synced}), do: "Synced"
  defp hardware_status_label(_draft), do: "Ready"

  defp driver_live_action?(live_action), do: live_action in [:driver_show, :driver_cell]

  defp driver_items(slaves, adapter_id, live_action) when is_list(slaves) do
    slaves
    |> Enum.with_index()
    |> Enum.map(fn entry ->
      {slave, _index} = entry
      driver_id = driver_entry_id(entry)

      %{
        id: driver_id,
        label: humanize_slave_title(driver_id),
        detail: driver_description(Map.get(slave, "driver", "")),
        path: driver_path(adapter_id, driver_id, live_action),
        status: driver_process_mode_text(slave)
      }
    end)
  end

  defp driver_items(_slaves, _adapter_id, _live_action), do: []

  defp driver_rows(slaves, nil) when is_list(slaves), do: Enum.with_index(slaves)

  defp driver_rows(slaves, selected_driver_id) when is_list(slaves) do
    slaves
    |> Enum.with_index()
    |> Enum.filter(fn {slave, index} -> driver_entry_id({slave, index}) == selected_driver_id end)
  end

  defp driver_rows(_slaves, _selected_driver_id), do: []

  defp selected_driver_entry(slaves, selected_driver_id) when is_binary(selected_driver_id) do
    Enum.find(driver_rows(slaves, selected_driver_id), fn {_slave, _index} -> true end)
  end

  defp selected_driver_entry(_slaves, _selected_driver_id), do: nil

  defp driver_entry_id({slave, index}) do
    case slave |> Map.get("name", "") |> to_string() |> String.trim() do
      "" -> "slave_#{index + 1}"
      name -> name
    end
  end

  defp show_driver_link?(nil, _slave), do: true
  defp show_driver_link?(_selected_driver_id, _slave), do: false

  defp humanize_slave_title(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp driver_description(driver_name) do
    "#{driver_name} controls #{driver_signals_text(driver_name)}."
  end

  defp driver_signals_text(driver_name) do
    case driver_signals(driver_name) do
      [] -> "no process data signals"
      signals -> Enum.map_join(signals, ", ", &to_string/1)
    end
  end

  defp driver_signals(driver_name) when is_binary(driver_name) do
    module =
      driver_name
      |> String.trim()
      |> String.trim_leading("Elixir.")
      |> then(&Module.concat([&1]))

    if Code.ensure_loaded?(module) and function_exported?(module, :signal_model, 2) do
      module
      |> apply(:signal_model, [%{}, []])
      |> Keyword.keys()
    else
      []
    end
  rescue
    _error -> []
  end

  defp driver_signals(_driver_name), do: []

  defp driver_process_mode_text(slave) do
    case Map.get(slave, "process_data_mode", "none") do
      "all" ->
        domain = Map.get(slave, "process_data_domain", "")
        "All signals in #{domain}"

      _other ->
        "No process data"
    end
  end
end
