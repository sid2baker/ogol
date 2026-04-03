defmodule OgolWeb.Studio.SimulatorLive do
  use OgolWeb, :live_view

  alias EtherCAT.Backend
  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATHardwareConfig
  alias Ogol.Session
  alias Ogol.Simulator.Config.EtherCAT, as: EtherCATSimulatorConfig
  alias Ogol.Simulator.Config.Source, as: SimulatorConfigSource
  alias OgolWeb.Live.SessionSync
  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Studio.Library, as: StudioLibrary

  @adapter_id "ethercat"
  @refresh_interval_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
    end

    {:ok,
     socket
     |> SessionSync.attach()
     |> assign(:page_title, "Simulator Studio")
     |> assign(
       :page_summary,
       "Author simulator behavior per adapter and manage simulator runtime separately from topology startup."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :simulator)
     |> assign(:hmi_subnav, nil)
     |> assign(:adapter_id, nil)
     |> assign(:requested_view, :config)
     |> assign(:simulator_draft, nil)
     |> assign(:simulator_config, nil)
     |> assign(:simulator_source, "")
     |> assign(:simulator_form, normalize_simulator_form(nil))
     |> assign(:hardware_config, nil)
     |> assign(:validation_errors, [])
     |> assign(:sync_state, :synced)
     |> assign(:sync_diagnostics, [])
     |> assign(:simulator_feedback, nil)
     |> assign(:ethercat_session, %{})
     |> assign(:available_ethercat_drivers, available_driver_options())
     |> assign(:available_raw_interfaces, Session.available_raw_interfaces())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    adapter_id =
      if socket.assigns.live_action in [:show, :cell], do: params["adapter_id"], else: nil

    socket =
      socket
      |> maybe_ensure_adapter_config(adapter_id)
      |> SessionSync.refresh()
      |> assign(:adapter_id, adapter_id)
      |> assign(:requested_view, requested_view(params["view"]))
      |> assign(:hmi_subnav, if(adapter_id == @adapter_id, do: :ethercat, else: nil))
      |> load_page_state()

    {:noreply, maybe_canonicalize_path(socket, adapter_id, params["view"])}
  end

  @impl true
  def handle_info({:operations, operations}, socket) do
    {:noreply,
     socket
     |> SessionSync.apply_operations(operations)
     |> load_page_state()}
  end

  def handle_info(:refresh_simulator, socket) do
    schedule_refresh()
    {:noreply, load_page_state(socket)}
  end

  @impl true
  def handle_event("select_view", %{"view" => raw_view}, socket) do
    {:noreply, push_patch(socket, to: current_path(socket.assigns.adapter_id, raw_view, socket))}
  end

  def handle_event("request_transition", %{"transition" => "start_simulation"}, socket) do
    case socket.assigns.simulator_config do
      %{adapter: :ethercat} = config ->
        case Session.start_simulation_config(config) do
          {:ok, runtime} ->
            {:noreply,
             socket
             |> assign(:simulator_feedback, start_feedback(:ok, runtime))
             |> load_page_state()}

          {:error, reason} ->
            {:noreply, assign(socket, :simulator_feedback, start_feedback(:error, reason))}
        end

      _other ->
        {:noreply, assign(socket, :simulator_feedback, missing_config_feedback())}
    end
  end

  def handle_event("request_transition", %{"transition" => "stop_simulation"}, socket) do
    case Session.stop_simulation(@adapter_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:simulator_feedback, stop_feedback(:ok))
         |> load_page_state()}

      {:error, reason} ->
        {:noreply, assign(socket, :simulator_feedback, stop_feedback(:error, reason))}
    end
  end

  def handle_event("request_transition", %{"transition" => "reset_from_hardware"}, socket) do
    case socket.assigns.hardware_config do
      %EtherCATHardwareConfig{} = config ->
        draft = Session.put_simulator_config(:ethercat, derived_simulator_config(config))

        {:noreply,
         socket
         |> assign(:simulator_feedback, reset_feedback(config.id))
         |> assign(:simulator_draft, draft)
         |> load_page_state()}

      _other ->
        {:noreply, assign(socket, :simulator_feedback, missing_hardware_feedback())}
    end
  end

  def handle_event("change_visual", %{"simulator_config" => params}, socket) do
    form = merge_simulator_form(socket.assigns.simulator_form, params)
    {:noreply, persist_visual_form(socket, form)}
  end

  def handle_event("change_source", %{"draft" => %{"source" => source}}, socket) do
    case SimulatorConfigSource.from_source(source) do
      {:ok, %{adapter: :ethercat} = config} ->
        draft = Session.save_simulator_config_source(@adapter_id, source, config, :synced, [])

        {:noreply,
         socket
         |> assign(:simulator_draft, draft)
         |> assign(:simulator_config, config)
         |> assign(:simulator_source, source)
         |> assign(
           :simulator_form,
           normalize_simulator_form(Session.ethercat_simulator_form_from_config(config))
         )
         |> assign(:validation_errors, [])
         |> assign(:sync_state, :synced)
         |> assign(:sync_diagnostics, [])}

      :unsupported ->
        diagnostics = [
          "Current source can no longer be represented by the EtherCAT simulator visual editor."
        ]

        draft =
          Session.save_simulator_config_source(
            @adapter_id,
            source,
            nil,
            :unsupported,
            diagnostics
          )

        {:noreply,
         socket
         |> assign(:simulator_draft, draft)
         |> assign(:simulator_config, nil)
         |> assign(:simulator_source, source)
         |> assign(:validation_errors, [])
         |> assign(:sync_state, :unsupported)
         |> assign(:sync_diagnostics, diagnostics)}
    end
  end

  def handle_event("add_device", _params, socket) do
    form =
      socket.assigns.simulator_form
      |> normalize_simulator_form()
      |> update_in(["devices"], &(&1 ++ [empty_device_row()]))

    {:noreply, persist_visual_form(socket, form)}
  end

  def handle_event("remove_device", %{"index" => index}, socket) do
    form =
      socket.assigns.simulator_form
      |> normalize_simulator_form()
      |> update_in(["devices"], &remove_row(&1, index, empty_device_row()))

    {:noreply, persist_visual_form(socket, form)}
  end

  def handle_event("add_connection", _params, socket) do
    form =
      socket.assigns.simulator_form
      |> normalize_simulator_form()
      |> update_in(["connections"], &(&1 ++ [empty_connection_row()]))

    {:noreply, persist_visual_form(socket, form)}
  end

  def handle_event("remove_connection", %{"index" => index}, socket) do
    form =
      socket.assigns.simulator_form
      |> normalize_simulator_form()
      |> update_in(["connections"], &remove_row(&1, index, empty_connection_row()))

    {:noreply, persist_visual_form(socket, form)}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :simulator_items,
        simulator_items(
          if(assigns.live_action == :show, do: assigns.adapter_id, else: nil),
          assigns.simulator_draft,
          assigns.ethercat_session
        )
      )

    ~H"""
    <%= if @live_action == :cell do %>
      <.simulator_cell_body
        :if={@simulator_draft}
        simulator_form={@simulator_form}
        simulator_source={@simulator_source}
        simulator_config={@simulator_config}
        hardware_config={@hardware_config}
        ethercat_session={@ethercat_session}
        requested_view={@requested_view}
        available_ethercat_drivers={@available_ethercat_drivers}
        available_raw_interfaces={@available_raw_interfaces}
      />

      <section :if={!@simulator_draft} class="app-panel px-5 py-5">
        <p class="app-kicker">No Simulator</p>
        <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
          EtherCAT simulator config is not available in the current workspace
        </h2>
      </section>
    <% else %>
      <%= if @live_action == :show do %>
        <section class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
          <StudioLibrary.list
            title="Simulator"
            items={@simulator_items}
            current_id={@adapter_id}
          />

          <section class="grid gap-5">
            <.simulator_cell_panel
              simulator_draft={@simulator_draft}
              simulator_form={@simulator_form}
              simulator_source={@simulator_source}
              simulator_config={@simulator_config}
              hardware_config={@hardware_config}
              requested_view={@requested_view}
              ethercat_session={@ethercat_session}
              simulator_feedback={@simulator_feedback}
              validation_errors={@validation_errors}
              sync_state={@sync_state}
              sync_diagnostics={@sync_diagnostics}
              available_ethercat_drivers={@available_ethercat_drivers}
              available_raw_interfaces={@available_raw_interfaces}
            />
          </section>
        </section>
      <% else %>
        <section class="grid gap-5">
          <StudioLibrary.list title="Simulator" items={@simulator_items} current_id={nil} />
        </section>
      <% end %>
    <% end %>
    """
  end

  attr(:simulator_draft, :any, required: true)
  attr(:simulator_form, :map, required: true)
  attr(:simulator_source, :string, default: "")
  attr(:simulator_config, :any, default: nil)
  attr(:hardware_config, :any, default: nil)
  attr(:requested_view, :atom, required: true)
  attr(:ethercat_session, :map, default: %{})
  attr(:simulator_feedback, :map, default: nil)
  attr(:validation_errors, :list, default: [])
  attr(:sync_state, :atom, default: :synced)
  attr(:sync_diagnostics, :list, default: [])
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:available_raw_interfaces, :list, default: [])

  defp simulator_cell_panel(assigns) do
    ~H"""
    <StudioCell.cell :if={@simulator_draft} body_class="min-h-[60rem]">
      <:actions>
        <StudioCell.action_button
          :for={control <- simulator_controls(assigns)}
          type="button"
          phx-click="request_transition"
          phx-value-transition={control.id}
          data-test={control.data_test}
          variant={control.variant}
          disabled={!control.enabled?}
          title={control.disabled_reason}
        >
          {control.label}
        </StudioCell.action_button>
      </:actions>

      <:notice :if={simulator_notice(assigns)}>
        <% notice = simulator_notice(assigns) %>
        <StudioCell.notice tone={notice.tone} title={notice.title} message={notice.message} />
      </:notice>

      <:views>
        <StudioCell.view_button
          :for={view <- simulator_views()}
          type="button"
          phx-click="select_view"
          phx-value-view={view.id}
          selected={@requested_view == view.id}
          available={true}
          data-test={"simulator-view-#{view.id}"}
        >
          {view.label}
        </StudioCell.view_button>
      </:views>

      <:body>
        <.simulator_cell_body
          simulator_form={@simulator_form}
          simulator_source={@simulator_source}
          simulator_config={@simulator_config}
          hardware_config={@hardware_config}
          ethercat_session={@ethercat_session}
          available_ethercat_drivers={@available_ethercat_drivers}
          available_raw_interfaces={@available_raw_interfaces}
          requested_view={@requested_view}
        />
      </:body>
    </StudioCell.cell>

    <section :if={!@simulator_draft} class="app-panel px-5 py-5">
      <p class="app-kicker">No Simulator</p>
      <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
        EtherCAT simulator config is not available in the current workspace
      </h2>
    </section>
    """
  end

  attr(:simulator_form, :map, required: true)
  attr(:simulator_source, :string, default: "")
  attr(:simulator_config, :any, default: nil)
  attr(:hardware_config, :any, default: nil)
  attr(:ethercat_session, :map, default: %{})
  attr(:requested_view, :atom, default: :config)
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:available_raw_interfaces, :list, default: [])

  defp simulator_cell_body(assigns) do
    ~H"""
    <.simulator_config_editor
      :if={@requested_view == :config}
      simulator_form={@simulator_form}
      simulator_config={@simulator_config}
      hardware_config={@hardware_config}
      ethercat_session={@ethercat_session}
      available_ethercat_drivers={@available_ethercat_drivers}
      available_raw_interfaces={@available_raw_interfaces}
    />

    <.simulator_source_editor
      :if={@requested_view == :source}
      simulator_source={@simulator_source}
    />
    """
  end

  attr(:simulator_form, :map, required: true)
  attr(:simulator_config, :any, default: nil)
  attr(:hardware_config, :any, default: nil)
  attr(:ethercat_session, :map, default: %{})
  attr(:available_ethercat_drivers, :list, default: [])
  attr(:available_raw_interfaces, :list, default: [])

  defp simulator_config_editor(assigns) do
    ~H"""
    <section class="grid gap-5">
      <section class="app-panel px-5 py-5" data-test="simulator-runtime-status">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div class="max-w-3xl">
            <p class="app-kicker">Runtime</p>
            <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
              EtherCAT simulator runtime
            </h2>
            <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
              This cell owns simulator runtime control. Reset defaults from the Hardware cell when
              you want the simulator config to follow workspace hardware again.
            </p>
          </div>

          <div class="max-w-sm rounded-2xl border border-[var(--app-border)] bg-[var(--app-surface-alt)] px-4 py-3">
            <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-[var(--app-text-subtle)]">
              Hardware Defaults
            </p>
            <p class="mt-2 text-sm text-[var(--app-text)]">
              {hardware_summary(@hardware_config)}
            </p>
          </div>
        </div>

        <div class="mt-4">
          <StudioCell.notice
            tone={runtime_notice_tone(@ethercat_session)}
            title={runtime_notice_title(@ethercat_session)}
            message={runtime_notice_message(@ethercat_session)}
          />
        </div>

        <div class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-6">
          <.detail_panel title="Adapter" body="ethercat" />
          <.detail_panel title="Backend" body={transport_summary(@simulator_config)} />
          <.detail_panel title="Topology" body={topology_summary(@simulator_config)} />
          <.detail_panel title="Devices" body={device_summary(@simulator_config)} />
          <.detail_panel title="Master" body={master_summary(@ethercat_session)} />
        </div>
      </section>

      <section class="app-panel px-5 py-5" data-test="simulator-config-form">
        <form phx-change="change_visual" class="space-y-8">
          <section class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
            <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
              <span class="font-medium text-[var(--app-text)]">Transport</span>
              <select name="simulator_config[transport]" class="app-input w-full">
                <option value="udp" selected={Map.get(@simulator_form, "transport") == "udp"}>UDP</option>
                <option value="raw" selected={Map.get(@simulator_form, "transport") == "raw"}>Raw</option>
                <option value="redundant" selected={Map.get(@simulator_form, "transport") == "redundant"}>
                  Redundant
                </option>
              </select>
            </label>

            <label
              :if={udp_transport?(@simulator_form)}
              class="space-y-2 text-sm text-[var(--app-text-muted)]"
            >
              <span class="font-medium text-[var(--app-text)]">Host</span>
              <input
                name="simulator_config[host]"
                value={Map.get(@simulator_form, "host", "")}
                class="app-input w-full"
              />
            </label>

            <label
              :if={udp_transport?(@simulator_form)}
              class="space-y-2 text-sm text-[var(--app-text-muted)]"
            >
              <span class="font-medium text-[var(--app-text)]">Port</span>
              <input
                name="simulator_config[port]"
                value={Map.get(@simulator_form, "port", "")}
                class="app-input w-full"
              />
            </label>

            <.interface_field
              :if={uses_primary_interface?(@simulator_form)}
              label="Primary Interface"
              name="simulator_config[primary_interface]"
              value={Map.get(@simulator_form, "primary_interface", "")}
              options={@available_raw_interfaces}
            />

            <.interface_field
              :if={redundant_transport?(@simulator_form)}
              label="Secondary Interface"
              name="simulator_config[secondary_interface]"
              value={Map.get(@simulator_form, "secondary_interface", "")}
              options={@available_raw_interfaces}
            />
          </section>

          <section class="space-y-4">
            <div class="flex items-center justify-between gap-4">
              <div>
                <h3 class="text-lg font-semibold text-[var(--app-text)]">Devices</h3>
                <p class="text-sm text-[var(--app-text-muted)]">
                  Simulated devices are hydrated directly from EtherCAT drivers.
                </p>
              </div>

              <button type="button" phx-click="add_device" class="app-button-secondary">Add Device</button>
            </div>

            <div class="grid gap-4">
              <section
                :for={{device, index} <- Enum.with_index(@simulator_form["devices"])}
                class="app-panel px-4 py-4"
                data-test={"simulator-device-#{index}"}
              >
                <div class="grid gap-4 md:grid-cols-2">
                  <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                    <span class="font-medium text-[var(--app-text)]">Name</span>
                    <input
                      name={"simulator_config[devices][#{index}][name]"}
                      value={Map.get(device, "name", "")}
                      class="app-input w-full"
                    />
                  </label>

                  <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                    <span class="font-medium text-[var(--app-text)]">Driver</span>
                    <select
                      name={"simulator_config[devices][#{index}][driver]"}
                      class="app-input w-full"
                    >
                      <option :for={driver <- @available_ethercat_drivers} value={driver} selected={Map.get(device, "driver") == driver}>
                        {driver}
                      </option>
                    </select>
                  </label>
                </div>

                <div class="mt-3 flex justify-end">
                  <button
                    type="button"
                    phx-click="remove_device"
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
                <h3 class="text-lg font-semibold text-[var(--app-text)]">Connections</h3>
                <p class="text-sm text-[var(--app-text-muted)]">
                  Wire simulator signals explicitly to model bench loopbacks and cross-device feedback.
                </p>
              </div>

              <button type="button" phx-click="add_connection" class="app-button-secondary">
                Add Connection
              </button>
            </div>

            <div class="grid gap-4">
              <section
                :for={{connection, index} <- Enum.with_index(@simulator_form["connections"])}
                class="app-panel px-4 py-4"
                data-test={"simulator-connection-#{index}"}
              >
                <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
                  <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                    <span class="font-medium text-[var(--app-text)]">Source Device</span>
                    <input
                      name={"simulator_config[connections][#{index}][source_device]"}
                      value={Map.get(connection, "source_device", "")}
                      class="app-input w-full"
                    />
                  </label>

                  <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                    <span class="font-medium text-[var(--app-text)]">Source Signal</span>
                    <input
                      name={"simulator_config[connections][#{index}][source_signal]"}
                      value={Map.get(connection, "source_signal", "")}
                      class="app-input w-full"
                    />
                  </label>

                  <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                    <span class="font-medium text-[var(--app-text)]">Target Device</span>
                    <input
                      name={"simulator_config[connections][#{index}][target_device]"}
                      value={Map.get(connection, "target_device", "")}
                      class="app-input w-full"
                    />
                  </label>

                  <label class="space-y-2 text-sm text-[var(--app-text-muted)]">
                    <span class="font-medium text-[var(--app-text)]">Target Signal</span>
                    <input
                      name={"simulator_config[connections][#{index}][target_signal]"}
                      value={Map.get(connection, "target_signal", "")}
                      class="app-input w-full"
                    />
                  </label>
                </div>

                <div class="mt-3 flex justify-end">
                  <button
                    type="button"
                    phx-click="remove_connection"
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
    </section>
    """
  end

  attr(:simulator_source, :string, default: "")

  defp simulator_source_editor(assigns) do
    ~H"""
    <section class="app-panel px-5 py-5" data-test="simulator-config-source">
      <form phx-change="change_source">
        <textarea
          name="draft[source]"
          class="min-h-[36rem] w-full rounded-md border border-[var(--app-border)] bg-[var(--app-canvas)] p-4 font-mono text-sm text-[var(--app-text)]"
        ><%= @simulator_source %></textarea>
      </form>
    </section>
    """
  end

  defp load_page_state(socket) do
    preserve_unsaved_form? = preserve_unsaved_form?(socket)
    current_form = Map.get(socket.assigns, :simulator_form)
    current_validation_errors = Map.get(socket.assigns, :validation_errors, [])

    draft = SessionSync.fetch_simulator_config(socket, :ethercat)
    config = SessionSync.simulator_config_model(socket, :ethercat)
    hardware_config = SessionSync.hardware_config_model(socket, :ethercat)
    source = draft_source(draft, config)

    socket =
      socket
      |> assign(:simulator_draft, draft)
      |> assign(:simulator_config, config)
      |> assign(:simulator_source, source)
      |> assign(:hardware_config, hardware_config)
      |> assign(:sync_state, if(draft, do: draft.sync_state, else: :synced))
      |> assign(:sync_diagnostics, if(draft, do: List.wrap(draft.sync_diagnostics), else: []))
      |> assign(:validation_errors, [])
      |> assign(:ethercat_session, Session.ethercat_session())

    if preserve_unsaved_form? do
      socket
      |> assign(:simulator_form, normalize_simulator_form(current_form))
      |> assign(:validation_errors, current_validation_errors)
    else
      assign(socket, :simulator_form, draft_form(draft, config))
    end
  end

  defp maybe_ensure_adapter_config(socket, @adapter_id) do
    case SessionSync.fetch_simulator_config(socket, :ethercat) do
      nil ->
        case SessionSync.hardware_config_model(socket, :ethercat) do
          %EtherCATHardwareConfig{} = config ->
            _draft = Session.put_simulator_config(:ethercat, derived_simulator_config(config))
            socket

          _other ->
            _draft = Session.create_simulator_config(:ethercat)
            socket
        end

      _draft ->
        socket
    end
  end

  defp maybe_ensure_adapter_config(socket, _adapter_id), do: socket

  defp persist_visual_form(socket, form) do
    case Session.preview_ethercat_simulator_config(form) do
      {:ok, %{adapter: :ethercat} = config} ->
        source = SimulatorConfigSource.to_source(config)
        draft = Session.save_simulator_config_source(@adapter_id, source, config, :synced, [])

        socket
        |> assign(:simulator_draft, draft)
        |> assign(:simulator_config, config)
        |> assign(:simulator_source, source)
        |> assign(:simulator_form, form)
        |> assign(:validation_errors, [])
        |> assign(:sync_state, :synced)
        |> assign(:sync_diagnostics, [])

      {:error, reason} ->
        socket
        |> assign(:simulator_form, form)
        |> assign(:validation_errors, [inspect(reason)])
    end
  end

  defp draft_source(%{source: source}, _config) when is_binary(source), do: source

  defp draft_source(_draft, %{adapter: :ethercat} = config),
    do: SimulatorConfigSource.to_source(config)

  defp draft_source(_draft, _config), do: SimulatorConfigSource.default_source(:ethercat)

  defp draft_form(_draft, %{adapter: :ethercat} = config) do
    config
    |> Session.ethercat_simulator_form_from_config()
    |> normalize_simulator_form()
  end

  defp draft_form(%{model: %{adapter: :ethercat} = config}, _other), do: draft_form(nil, config)
  defp draft_form(_draft, _config), do: normalize_simulator_form(nil)

  defp merge_simulator_form(current_form, params) do
    current_form
    |> normalize_simulator_form()
    |> deep_merge_maps(Enum.into(params, %{}, fn {key, value} -> {to_string(key), value} end))
    |> normalize_simulator_form()
  end

  defp preserve_unsaved_form?(socket) do
    socket.assigns
    |> Map.get(:validation_errors, [])
    |> List.wrap()
    |> Kernel.!=([])
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

  defp normalize_simulator_form(form) when is_map(form) do
    form
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("transport", "udp")
    |> Map.put_new("host", "127.0.0.2")
    |> Map.put_new("port", "0")
    |> Map.put_new("primary_interface", "")
    |> Map.put_new("secondary_interface", "")
    |> normalize_device_rows()
    |> normalize_connection_rows()
  end

  defp normalize_simulator_form(_form) do
    Session.default_ethercat_simulator_form()
    |> normalize_simulator_form()
  end

  defp normalize_device_rows(form) do
    devices =
      case Map.get(form, "devices") do
        rows when is_map(rows) ->
          rows
          |> Enum.sort_by(fn {index, _row} -> parse_index(index) end)
          |> Enum.map(fn {_index, row} -> normalize_device_row(row) end)

        rows when is_list(rows) ->
          Enum.map(rows, &normalize_device_row/1)

        _other ->
          [empty_device_row()]
      end

    Map.put(form, "devices", if(devices == [], do: [empty_device_row()], else: devices))
  end

  defp normalize_connection_rows(form) do
    connections =
      case Map.get(form, "connections") do
        rows when is_map(rows) ->
          rows
          |> Enum.sort_by(fn {index, _row} -> parse_index(index) end)
          |> Enum.map(fn {_index, row} -> normalize_connection_row(row) end)

        rows when is_list(rows) ->
          Enum.map(rows, &normalize_connection_row/1)

        _other ->
          [empty_connection_row()]
      end

    Map.put(
      form,
      "connections",
      if(connections == [], do: [empty_connection_row()], else: connections)
    )
  end

  defp normalize_device_row(row) when is_map(row) do
    row
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value || "")} end)
    |> Map.put_new("name", "")
    |> Map.put_new("driver", hd(available_driver_options()))
  end

  defp normalize_device_row(_row), do: empty_device_row()

  defp normalize_connection_row(row) when is_map(row) do
    row
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value || "")} end)
    |> Map.put_new("source_device", "")
    |> Map.put_new("source_signal", "")
    |> Map.put_new("target_device", "")
    |> Map.put_new("target_signal", "")
  end

  defp normalize_connection_row(_row), do: empty_connection_row()

  defp empty_device_row do
    %{
      "name" => "",
      "driver" => hd(available_driver_options())
    }
  end

  defp empty_connection_row do
    %{
      "source_device" => "",
      "source_signal" => "",
      "target_device" => "",
      "target_signal" => ""
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

  defp simulator_controls(assigns) do
    [
      %{
        id: "reset_from_hardware",
        label: "Reset From Hardware",
        data_test: "reset-from-hardware",
        variant: :secondary,
        enabled?: is_struct(assigns.hardware_config),
        disabled_reason: reset_disabled_reason(assigns.hardware_config)
      },
      start_or_stop_control(assigns.ethercat_session, assigns.simulator_config)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp start_or_stop_control(session, _config) do
    if simulator_running?(session) do
      %{
        id: "stop_simulation",
        label: "Stop Simulation",
        data_test: "simulation-stop-current",
        variant: :secondary,
        enabled?: true,
        disabled_reason: nil
      }
    else
      %{
        id: "start_simulation",
        label: "Start Simulation",
        data_test: "start-simulation",
        variant: :primary,
        enabled?: true,
        disabled_reason: nil
      }
    end
  end

  defp simulator_views do
    [
      %{id: :config, label: "Config"},
      %{id: :source, label: "Source"}
    ]
  end

  defp simulator_notice(assigns) do
    cond do
      not is_nil(assigns.simulator_feedback) ->
        %{
          tone: feedback_tone(assigns.simulator_feedback),
          title: assigns.simulator_feedback.summary,
          message: assigns.simulator_feedback.detail
        }

      assigns.validation_errors != [] ->
        %{
          tone: :warning,
          title: "Visual update blocked",
          message: List.first(assigns.validation_errors)
        }

      assigns.sync_state == :unsupported ->
        %{
          tone: :error,
          title: "Visual editor unavailable",
          message: Enum.join(List.wrap(assigns.sync_diagnostics), " ")
        }

      true ->
        nil
    end
  end

  defp reset_disabled_reason(%EtherCATHardwareConfig{}), do: nil
  defp reset_disabled_reason(_other), do: "Create a hardware config first."

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
  defp requested_view("source"), do: :source
  defp requested_view(_other), do: :config

  defp maybe_canonicalize_path(socket, _requested_adapter_id, _requested_view)
       when socket.assigns.live_action not in [:show, :cell],
       do: socket

  defp maybe_canonicalize_path(
         %{assigns: %{simulator_draft: nil}} = socket,
         _requested_id,
         _view
       ),
       do: socket

  defp maybe_canonicalize_path(socket, requested_adapter_id, requested_view) do
    current_adapter_id = socket.assigns.adapter_id || @adapter_id
    selected_view = socket.assigns.requested_view

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

  defp page_path(adapter_id, :config), do: "/studio/simulator/#{adapter_id}"
  defp page_path(adapter_id, :source), do: "/studio/simulator/#{adapter_id}/source"

  defp page_path(adapter_id, view) when is_binary(view),
    do: page_path(adapter_id, requested_view(view))

  defp cell_path(adapter_id, :config), do: "/studio/cells/simulator/#{adapter_id}"
  defp cell_path(adapter_id, :source), do: "/studio/cells/simulator/#{adapter_id}/source"

  defp cell_path(adapter_id, view) when is_binary(view),
    do: cell_path(adapter_id, requested_view(view))

  defp simulator_items(current_id, draft, ethercat_session) do
    [
      %{
        id: @adapter_id,
        label: "EtherCAT",
        detail: simulator_detail(draft),
        path: page_path(@adapter_id, :config),
        status:
          if(current_id == @adapter_id,
            do: "open",
            else: simulator_status_label(draft, ethercat_session)
          )
      }
    ]
  end

  defp simulator_detail(%{model: %{devices: devices}}),
    do: "#{length(devices)} simulated device(s)"

  defp simulator_detail(_draft), do: "Adapter-specific simulator config"

  defp simulator_status_label(_draft, %{simulator_status: %{lifecycle: :running}}), do: "Running"
  defp simulator_status_label(%{sync_state: :unsupported}, _session), do: "Source-only"
  defp simulator_status_label(%{sync_state: :synced}, _session), do: "Synced"
  defp simulator_status_label(_draft, _session), do: "Ready"

  attr(:title, :string, required: true)
  attr(:body, :string, required: true)

  defp detail_panel(assigns) do
    ~H"""
    <div class="border border-white/8 bg-slate-900/70 px-3 py-3">
      <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">{@title}</p>
      <p class="mt-2 text-[12px] text-slate-200">{@body}</p>
    </div>
    """
  end

  defp runtime_notice_tone(%{simulator_status: %{lifecycle: :running}}), do: :good

  defp runtime_notice_tone(session) do
    if master_state(session) in [:stopped, :idle], do: :warning, else: :info
  end

  defp runtime_notice_title(%{simulator_status: %{lifecycle: :running}}), do: "Simulator running"

  defp runtime_notice_title(session) do
    if master_state(session) in [:stopped, :idle], do: "Simulator stopped", else: "Master active"
  end

  defp runtime_notice_message(session), do: runtime_summary(session)

  defp runtime_summary(%{simulator_status: %{lifecycle: :running, backend: backend}} = session) do
    "simulator #{backend_summary(backend)}; master #{format_state(master_state(session))}"
  end

  defp runtime_summary(session) do
    "simulator not running; master #{format_state(master_state(session))}"
  end

  defp feedback_tone(%{status: status}) when status in [:ok, :pending, :info], do: :info
  defp feedback_tone(%{status: status}) when status in [:warning, :warn], do: :warning
  defp feedback_tone(_feedback), do: :error

  defp missing_config_feedback do
    %{
      status: :error,
      summary: "Simulation start failed",
      detail: "Define a current EtherCAT simulator config first."
    }
  end

  defp missing_hardware_feedback do
    %{
      status: :warning,
      summary: "Reset unavailable",
      detail: "Create a current EtherCAT hardware config first."
    }
  end

  defp reset_feedback(config_id) do
    %{
      status: :info,
      summary: "simulator reset from hardware #{config_id}",
      detail: "the simulator draft now mirrors the current hardware config"
    }
  end

  defp start_feedback(:ok, runtime) do
    %{
      status: :ok,
      summary: "simulation started",
      detail:
        "simulator port=#{runtime.port || 0} devices=#{Enum.join(Enum.map(runtime.slaves, &to_string/1), ", ")}"
    }
  end

  defp start_feedback(:error, reason) do
    %{
      status: :error,
      summary: "simulation start failed",
      detail: inspect(reason)
    }
  end

  defp stop_feedback(:ok) do
    %{
      status: :ok,
      summary: "simulation stopped",
      detail: "the simulator runtime is stopped"
    }
  end

  defp stop_feedback(:error, reason) do
    %{
      status: :error,
      summary: "simulation stop failed",
      detail: inspect(reason)
    }
  end

  defp master_summary(session), do: format_state(master_state(session))

  defp master_state(%{state: {:ok, state}}), do: state
  defp master_state(%{state: {:error, :not_started}}), do: :stopped
  defp master_state(%{state: {:error, reason}}), do: {:error, reason}
  defp master_state(%{state: state}), do: state
  defp master_state(_session), do: :idle

  defp simulator_running?(%{simulator_status: %{lifecycle: :running}}), do: true
  defp simulator_running?(_session), do: false

  defp format_state(state) when is_atom(state), do: state |> Atom.to_string() |> String.upcase()
  defp format_state({:error, reason}), do: "ERROR #{inspect(reason)}"
  defp format_state(state), do: to_string(state)

  defp hardware_summary(%EtherCATHardwareConfig{} = config) do
    "#{config.id} · #{length(config.slaves)} slave(s)"
  end

  defp hardware_summary(_config), do: "no hardware defaults available"

  defp transport_summary(%{adapter: :ethercat} = config) do
    case EtherCATSimulatorConfig.transport_mode(config) do
      :raw ->
        "raw #{EtherCATSimulatorConfig.primary_interface(config) || "unassigned"}"

      :redundant ->
        primary = EtherCATSimulatorConfig.primary_interface(config) || "unassigned"
        secondary = EtherCATSimulatorConfig.secondary_interface(config) || "unassigned"
        "redundant #{primary} -> #{secondary}"

      :udp ->
        "udp #{format_ip(EtherCATSimulatorConfig.host(config))}:#{EtherCATSimulatorConfig.port(config) || 0}"
    end
  end

  defp transport_summary(_config), do: "unconfigured"

  defp topology_summary(%{adapter: :ethercat, topology: topology}) when is_atom(topology) do
    topology |> Atom.to_string() |> String.upcase()
  end

  defp topology_summary(_config), do: "unconfigured"

  defp device_summary(%{devices: devices}) when is_list(devices) do
    names = Enum.map(devices, &to_string(&1.name))
    "#{length(names)} device(s): #{join_list(names, "none")}"
  end

  defp device_summary(_config), do: "0 device(s): none"

  defp schedule_refresh do
    Process.send_after(self(), :refresh_simulator, @refresh_interval_ms)
  end

  defp derived_simulator_config(%EtherCATHardwareConfig{} = config),
    do: EtherCATSimulatorConfig.from_hardware(config)

  defp udp_transport?(%{"transport" => "udp"}), do: true
  defp udp_transport?(_form), do: false

  defp raw_transport?(%{"transport" => "raw"}), do: true
  defp raw_transport?(_form), do: false

  defp redundant_transport?(%{"transport" => "redundant"}), do: true
  defp redundant_transport?(_form), do: false

  defp uses_primary_interface?(form), do: raw_transport?(form) or redundant_transport?(form)

  defp format_ip(nil), do: "unassigned"
  defp format_ip({a, b, c, d}), do: Enum.join([a, b, c, d], ".")
  defp format_ip(value), do: to_string(value)

  defp backend_summary(%Backend.Udp{port: port}), do: "udp port #{port}"

  defp backend_summary(%Backend.Raw{interface: interface}),
    do: "raw #{interface || "unassigned"}"

  defp backend_summary(%Backend.Redundant{} = backend) do
    "#{backend_summary(backend.primary)} -> #{backend_summary(backend.secondary)}"
  end

  defp backend_summary(backend), do: inspect(backend)

  defp join_list([], fallback), do: fallback
  defp join_list(items, _fallback), do: Enum.join(items, ", ")
end
