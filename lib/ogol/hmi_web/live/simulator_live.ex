defmodule Ogol.HMIWeb.SimulatorLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.{
    Bus,
    EventLog,
    HardwareConfig,
    HardwareConfigStore,
    HardwareContext,
    HardwareGateway
  }

  alias Ogol.HMIWeb.Components.{StudioCell, StudioLibrary}
  alias Ogol.Studio.Cell
  alias Ogol.Studio.SimulatorCell

  @event_limit 18
  @refresh_interval_ms 500
  @default_config_id "ethercat_demo"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Bus.subscribe(Bus.events_topic())
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Simulator Studio")
     |> assign(
       :page_summary,
       "Configure the simulated ring, inspect the generated source, and explicitly start or stop the simulator runtime."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :simulator)
     |> assign(:hardware_feedback, nil)
     |> assign(:hardware_feedback_ref, nil)
     |> assign(:requested_view, :visual)
     |> assign(:events, EventLog.recent(@event_limit))
     |> assign(:simulation_config_id, @default_config_id)
     |> assign(:simulation_driver_options, simulation_driver_options())
     |> load_state()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    config_id = params["config_id"] || @default_config_id
    {:noreply, socket |> load_simulation(config_id) |> load_state()}
  end

  @impl true
  def handle_info({:event_logged, _notification}, socket) do
    {:noreply,
     socket
     |> assign(:events, EventLog.recent(@event_limit))
     |> load_state()}
  end

  def handle_info(:refresh_simulator, socket) do
    schedule_refresh()
    {:noreply, load_state(socket)}
  end

  def handle_info({:hardware_action_result, ref, feedback}, socket) do
    if socket.assigns.hardware_feedback_ref == ref do
      simulation_form =
        case feedback do
          %{config: %HardwareConfig{} = config} ->
            :ok = HardwareConfigStore.put_config(config)
            config_form_from_config(config)

          _other ->
            socket.assigns.simulation_config_form
        end

      {:noreply,
       socket
       |> assign(:hardware_feedback_ref, nil)
       |> assign(:hardware_feedback, feedback)
       |> assign(:simulation_config_form, simulation_form)
       |> load_state()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_view", %{"view" => view}, socket) do
    view =
      view
      |> String.to_existing_atom()
      |> then(fn view -> if view in [:visual, :source], do: view, else: :visual end)

    {:noreply, assign(socket, :requested_view, view)}
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("new_simulation_config", _params, socket) do
    config = create_simulation_config()
    {:noreply, push_patch(socket, to: ~p"/studio/simulator/#{config.id}")}
  end

  def handle_event("change_simulation_config", %{"simulation_config" => params}, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      merged_form =
        socket.assigns.simulation_config_form
        |> merge_simulation_config_form(params)
        |> Map.put("id", socket.assigns.simulation_config_id)

      {:noreply,
       socket
       |> assign(:simulation_config_form, merged_form)
       |> maybe_persist_simulation_form(merged_form)
       |> load_state()}
    else
      {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("add_simulation_slave", _params, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      form =
        socket.assigns.simulation_config_form
        |> normalize_simulation_config_form()
        |> update_in(["slaves"], fn slaves -> slaves ++ [empty_simulation_slave_row()] end)

      {:noreply,
       socket
       |> assign(:simulation_config_form, form)
       |> maybe_persist_simulation_form(form)
       |> load_state()}
    else
      {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("remove_simulation_slave", %{"index" => index}, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      form =
        socket.assigns.simulation_config_form
        |> normalize_simulation_config_form()
        |> update_in(["slaves"], fn slaves -> remove_simulation_slave(slaves, index) end)

      {:noreply,
       socket
       |> assign(:simulation_config_form, form)
       |> maybe_persist_simulation_form(form)
       |> load_state()}
    else
      {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("request_transition", %{"transition" => "start_simulation"}, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      config_form =
        socket.assigns.simulation_config_form
        |> normalize_simulation_config_form()
        |> Map.put("id", socket.assigns.simulation_config_id)

      config_id = socket.assigns.simulation_config_id

      case HardwareGateway.start_simulation_config(config_form) do
        {:ok, %{config: config} = runtime} ->
          :ok = HardwareConfigStore.put_config(config)

          {:noreply,
           socket
           |> assign(:hardware_feedback_ref, nil)
           |> assign(
             :hardware_feedback,
             simulation_feedback(:ok, config.id, Map.delete(runtime, :config), config)
           )
           |> assign(:simulation_config_form, config_form_from_config(config))
           |> load_state()}

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

  def handle_event("request_transition", %{"transition" => "stop_simulation"}, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      case current_simulation_config_id(
             socket.assigns.hardware_context,
             socket.assigns.running_simulation_config_id,
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
          case HardwareGateway.stop_simulation(config_id) do
            :ok ->
              {:noreply,
               socket
               |> assign(:hardware_feedback_ref, nil)
               |> assign(:hardware_feedback, simulation_stop_feedback(:ok, config_id))
               |> load_state()}

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

  @impl true
  def render(assigns) do
    simulator_facts = SimulatorCell.facts_from_assigns(assigns)
    assigns = assign(assigns, :simulator_cell, Cell.derive(SimulatorCell, simulator_facts))

    ~H"""
    <section class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
      <StudioLibrary.list
        title="Simulator Configs"
        items={simulation_items(@simulation_library, @simulation_config_id, @running_simulation_config_id)}
        current_id={@simulation_config_id}
        empty_label="No simulator configs available."
      >
        <:actions>
          <button
            type="button"
            phx-click="new_simulation_config"
            class="app-button-secondary"
            data-test="new-simulation-config"
          >
            New
          </button>
        </:actions>
      </StudioLibrary.list>

      <StudioCell.cell
        body_class="min-h-[42rem]"
        panel_class="border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]"
        data-test="simulator-studio"
      >
        <:actions>
          <StudioCell.action_button
            :for={action <- @simulator_cell.actions}
            type="button"
            phx-click="request_transition"
            phx-value-transition={action.id}
            phx-disable-with={if(action.id == :start_simulation, do: "Starting...", else: nil)}
            variant={action.variant}
            disabled={!action.enabled?}
            title={action.disabled_reason}
            data-test={simulator_action_data_test(action.id)}
          >
            {action.label}
          </StudioCell.action_button>
        </:actions>

        <:views>
          <StudioCell.view_button
            :for={view <- @simulator_cell.views}
            type="button"
            phx-click="select_view"
            phx-value-view={view.id}
            selected={@simulator_cell.selected_view == view.id}
            available={view.available?}
            data-test={"simulator-mode-#{view.id}"}
          >
            {view.label}
          </StudioCell.view_button>
        </:views>

        <:notice :if={@simulator_cell.notice}>
          <StudioCell.notice
            tone={@simulator_cell.notice.tone}
            title={@simulator_cell.notice.title}
            message={@simulator_cell.notice.message}
          />
        </:notice>

        <:body>
          <div :if={@simulator_cell.selected_view == :source}>
            <.smart_cell_code
              title="Generated simulator cell"
              body={@simulation_source}
              data_test="simulation-cell-source"
            />
          </div>

          <div
            :if={@simulator_cell.selected_view == :visual and @hardware_context.observed.source == :simulator}
          >
            <div class="border border-cyan-300/15 bg-[#070b10] p-4" data-test="simulation-runtime-current">
              <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
                Current simulator state
              </p>
              <h4 class="mt-2 text-base font-semibold text-white">
                {@current_simulation_config_id || @simulation_config_id}
              </h4>
              <p class="mt-2 text-sm text-slate-300">
                The simulator is already running. Use the header action to stop it, or switch to <span class="font-medium text-white">Source</span> to inspect the generated smart-cell code.
              </p>

              <div class="mt-4 grid gap-2 sm:grid-cols-2">
                <.detail_panel title="Transport" body={simulation_transport_summary(@simulation_config_form)} />
                <.detail_panel title="Timing" body={simulation_timing_summary(@simulation_config_form)} />
                <.detail_panel title="Domains" body={simulation_domain_summary(@simulation_config_form)} />
                <.detail_panel title="Execution" body={simulation_execution_summary(@hardware_context, @running_simulation_config_id, @simulation_config_form)} />
              </div>
            </div>
          </div>

          <div
            :if={@simulator_cell.selected_view == :visual and @hardware_context.observed.source != :simulator}
          >
            <form
              id="simulation-config-form"
              phx-change="change_simulation_config"
              data-test="simulation-config-form"
              class="grid gap-3 border border-white/8 bg-[#070b10] p-3"
            >
              <fieldset disabled={!simulation_allowed?(@hardware_context)} class="contents">
                <div class="border-b border-white/8 pb-3">
                  <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
                    Draft ring
                  </p>
                  <p class="mt-1 text-sm text-slate-300">
                    Keep this at ring shape only: config id, label, and slave drivers. The simulator cell generates the runtime configuration from these values.
                  </p>
                </div>

                <div class="grid gap-3 md:grid-cols-2">
                  <label class="space-y-1.5">
                    <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Config Id</span>
                    <input
                      type="text"
                      name="simulation_config[id]"
                      value={@simulation_config_id}
                      class={input_classes("text-slate-400")}
                      readonly
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
                </div>

                <div class="space-y-2">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Slave Rows</span>
                      <p class="mt-1 text-[11px] text-slate-500">
                        This page only owns the simulated ring. EtherCAT master configuration now lives on the EtherCAT tab.
                      </p>
                    </div>

                    <button
                      type="button"
                      phx-click="add_simulation_slave"
                      disabled={!simulation_allowed?(@hardware_context)}
                      class={session_button_classes(:configure, simulation_allowed?(@hardware_context))}
                      data-test="add-simulation-slave"
                    >
                      Add slave
                    </button>
                  </div>

                  <div class="space-y-3" data-test="simulation-config-slaves">
                    <div
                      :for={{slave, index} <- Enum.with_index(simulation_slaves(@simulation_config_form))}
                      class="grid gap-3 border border-white/8 bg-slate-950/55 p-3"
                      data-test={"simulation-config-slave-#{index}"}
                    >
                      <div class="flex items-center justify-between gap-3 border-b border-white/8 pb-2">
                        <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-slate-400">
                          Slave {index + 1}
                        </p>

                        <button
                          :if={length(simulation_slaves(@simulation_config_form)) > 1}
                          type="button"
                          phx-click="remove_simulation_slave"
                          phx-value-index={index}
                          disabled={!simulation_allowed?(@hardware_context)}
                          class="border border-rose-400/25 bg-rose-400/10 px-2.5 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-rose-50 transition hover:border-rose-300/40 hover:bg-rose-300/15"
                          data-test={"remove-simulation-slave-#{index}"}
                        >
                          Remove
                        </button>
                      </div>

                      <div class="grid gap-3 md:grid-cols-2">
                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Name</span>
                          <input
                            type="text"
                            name={"simulation_config[slaves][#{index}][name]"}
                            value={Map.get(slave, "name", "")}
                            class={input_classes()}
                          />
                        </label>

                        <label class="space-y-1.5 xl:col-span-2">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Driver</span>
                          <select
                            name={"simulation_config[slaves][#{index}][driver]"}
                            class={input_classes()}
                          >
                            <option value="" selected={select_value?(Map.get(slave, "driver", ""), "")}>
                              choose driver
                            </option>
                            <option
                              :for={driver <- @simulation_driver_options}
                              value={simulation_driver_value(driver)}
                              selected={
                                select_value?(
                                  Map.get(slave, "driver", ""),
                                  simulation_driver_value(driver)
                                )
                              }
                            >
                              {simulation_driver_label(driver)}
                            </option>
                          </select>
                        </label>
                      </div>
                    </div>
                  </div>
                </div>
              </fieldset>
            </form>
          </div>
        </:body>
      </StudioCell.cell>
    </section>
    """
  end

  defp load_state(socket) do
    ethercat = HardwareGateway.ethercat_session()
    events = socket.assigns[:events] || EventLog.recent(@event_limit)

    simulation_config_form =
      socket.assigns[:simulation_config_form]
      |> Kernel.||(HardwareGateway.default_ethercat_simulation_form())
      |> normalize_simulation_config_form()

    effective_simulation_config =
      case HardwareGateway.preview_ethercat_simulation_config(simulation_config_form) do
        {:ok, config} -> config
        {:error, _reason} -> nil
      end

    hardware_context = HardwareContext.build(ethercat, events, [], mode: :testing)
    running_simulation_config_id = running_simulation_config_id(events, hardware_context)

    assign(socket,
      ethercat: ethercat,
      simulation_library: list_simulation_configs(),
      simulation_config_form: simulation_config_form,
      effective_simulation_config: effective_simulation_config,
      simulation_source:
        simulation_cell_code(effective_simulation_config, simulation_config_form),
      hardware_context: hardware_context,
      running_simulation_config_id: running_simulation_config_id,
      current_simulation_config_id:
        current_simulation_config_id(
          hardware_context,
          running_simulation_config_id,
          simulation_config_form
        )
    )
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_simulator, @refresh_interval_ms)
  end

  defp load_simulation(socket, config_id) do
    config = ensure_simulation_config(config_id)

    socket
    |> assign(:simulation_config_id, config.id)
    |> assign(:simulation_config_form, config_form_from_config(config))
    |> assign(:simulation_library, list_simulation_configs())
  end

  defp simulation_allowed?(hardware_context),
    do: SimulatorCell.simulation_allowed?(hardware_context)

  defp maybe_persist_simulation_form(socket, form) do
    case HardwareGateway.preview_ethercat_simulation_config(form) do
      {:ok, config} ->
        :ok = HardwareConfigStore.put_config(config)
        socket

      {:error, _reason} ->
        socket
    end
  end

  defp ensure_simulation_config(config_id) when is_binary(config_id) do
    case HardwareConfigStore.get_config(config_id) do
      %HardwareConfig{} = config ->
        if simulation_config?(config), do: config, else: create_simulation_config(config_id)

      _other ->
        create_simulation_config(config_id)
    end
  end

  defp create_simulation_config(config_id \\ next_simulation_config_id()) do
    form = simulation_form_for_id(config_id)
    {:ok, config} = HardwareGateway.preview_ethercat_simulation_config(form)
    :ok = HardwareConfigStore.put_config(config)
    config
  end

  defp next_simulation_config_id do
    existing_ids =
      list_simulation_configs()
      |> Enum.map(& &1.id)
      |> MapSet.new()

    Stream.iterate(2, &(&1 + 1))
    |> Enum.find_value(fn index ->
      candidate = "simulation_#{index}"
      if MapSet.member?(existing_ids, candidate), do: nil, else: candidate
    end)
  end

  defp simulation_form_for_id(@default_config_id) do
    HardwareGateway.default_ethercat_simulation_form()
  end

  defp simulation_form_for_id(config_id) do
    HardwareGateway.default_ethercat_simulation_form()
    |> Map.put("id", config_id)
    |> Map.put("label", humanize_simulation_id(config_id))
  end

  defp list_simulation_configs do
    HardwareGateway.list_hardware_configs()
    |> Enum.filter(&simulation_config?/1)
  end

  defp simulation_config?(%HardwareConfig{protocol: :ethercat, meta: meta}) do
    is_map(meta) and is_map(meta[:form]) and is_nil(meta[:captured_from])
  end

  defp simulation_config?(_other), do: false

  defp simulation_items(configs, current_id, running_config_id) do
    Enum.map(configs, fn config ->
      %{
        id: config.id,
        label: config.label,
        detail: "#{length(config.spec.slaves)} simulated slave(s)",
        path: ~p"/studio/simulator/#{config.id}",
        status: simulation_item_status(config.id, current_id, running_config_id)
      }
    end)
  end

  defp simulation_item_status(config_id, _current_id, running_config_id)
       when is_binary(running_config_id) and running_config_id == config_id,
       do: "running"

  defp simulation_item_status(config_id, current_id, _running_config_id)
       when config_id == current_id,
       do: "open"

  defp simulation_item_status(_config_id, _current_id, _running_config_id), do: nil

  defp simulator_action_data_test(:start_simulation), do: "start-simulation"
  defp simulator_action_data_test(:stop_simulation), do: "simulation-stop-current"

  defp humanize_simulation_id(config_id) do
    config_id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp current_simulation_config_id(%{observed: %{source: :simulator}}, running_config_id, form) do
    running_config_id || Map.get(form, "id", "draft")
  end

  defp current_simulation_config_id(_hardware_context, _running_config_id, _form), do: nil

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
      detail: "the simulator runtime is stopped"
    }
  end

  defp simulation_stop_feedback(:error, config_id, reason) do
    %{status: :error, summary: "simulation stop failed for #{config_id}", detail: inspect(reason)}
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

  defp select_value?(current, expected) do
    to_string(current || "") == to_string(expected || "")
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

  defp input_classes(extra \\ "") do
    [
      "w-full border border-white/10 bg-slate-900/80 px-3 py-2 font-mono text-[12px] text-slate-100 outline-none transition",
      "placeholder:text-slate-600 focus:border-cyan-400/40 focus:bg-slate-950/90",
      extra
    ]
    |> Enum.join(" ")
  end

  defp session_button_classes(_kind, false) do
    "cursor-not-allowed border border-white/10 bg-slate-900/60 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-slate-600"
  end

  defp session_button_classes(:configure, true) do
    "border border-cyan-400/25 bg-cyan-400/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-cyan-50 transition hover:border-cyan-300/40 hover:bg-cyan-300/15"
  end

  defp simulation_cell_code(%HardwareConfig{} = config, _form) do
    slave_lines =
      config.spec.slaves
      |> Enum.map(fn slave ->
        "slave :#{slave.name}, driver: #{format_module_name(slave.driver)}"
      end)
      |> Enum.map(&("    " <> &1))
      |> Enum.join("\n")

    """
    simulator_cell do
      hardware_config :#{config.id} do
        label #{inspect(config.label)}

    #{slave_lines}
      end
    end
    """
    |> String.trim()
  end

  defp simulation_cell_code(_config, form) do
    slaves =
      form
      |> simulation_slaves()
      |> Enum.map(fn slave ->
        driver =
          slave
          |> Map.get("driver", "")
          |> String.trim()
          |> case do
            "" -> "Driver.Module"
            value -> value
          end

        name =
          slave
          |> Map.get("name", "")
          |> String.trim()
          |> case do
            "" -> "unnamed"
            value -> value
          end

        "    slave :#{name}, driver: #{driver}"
      end)
      |> Enum.join("\n")

    """
    simulator_cell do
      hardware_config :#{Map.get(form, "id", "draft")} do
        label #{inspect(Map.get(form, "label", "Draft"))}

    #{slaves}
      end
    end
    """
    |> String.trim()
  end

  defp format_module_name(module) when is_atom(module) do
    module
    |> to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp format_module_name(module) when is_binary(module), do: module
  defp format_module_name(module), do: inspect(module)

  defp simulation_transport_summary(form) do
    form = normalize_simulation_config_form(form)

    "bind #{Map.get(form, "bind_ip", "127.0.0.1")} -> sim #{Map.get(form, "simulator_ip", "127.0.0.2")}"
  end

  defp simulation_timing_summary(form) do
    form = normalize_simulation_config_form(form)

    "stable #{Map.get(form, "scan_stable_ms", "20")}ms · poll #{Map.get(form, "scan_poll_ms", "10")}ms · frame #{Map.get(form, "frame_timeout_ms", "20")}ms"
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

  defp simulation_execution_summary(hardware_context, running_config_id, form) do
    config_id = Map.get(form, "id", "unsaved")

    cond do
      hardware_context.observed.source == :simulator and running_config_id == config_id ->
        "running this draft now"

      hardware_context.observed.source == :simulator and is_binary(running_config_id) ->
        "simulator active from #{running_config_id}"

      true ->
        "start boots the simulator into PREOP"
    end
  end

  defp config_form_from_config(config) do
    config
    |> Map.get(:meta, %{})
    |> Map.get(:form, %{})
    |> then(&Map.merge(HardwareGateway.default_ethercat_simulation_form(), &1))
    |> normalize_simulation_config_form()
  end

  defp merge_simulation_config_form(current_form, params) when is_map(params) do
    current_form = normalize_simulation_config_form(current_form)
    raw_params = stringify_form_map_keys(params)
    domain_ids = normalized_domain_ids(Map.get(current_form, "domains", []))

    current_form
    |> Map.merge(Map.drop(raw_params, ["slaves"]))
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
    HardwareGateway.default_ethercat_simulation_form()
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

  defp normalize_simulation_domain_row(row) when is_map(row) do
    row
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

  defp normalize_simulation_slave_row(row, domain_ids) when is_map(row) do
    default_domain_id = default_simulation_domain_id(domain_ids)

    row
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value || "")} end)
    |> Map.put_new("name", "")
    |> Map.put_new("driver", "")
    |> Map.put_new("target_state", "preop")
    |> Map.put_new("process_data_mode", "none")
    |> Map.put_new("process_data_domain", default_domain_id)
    |> Map.update("process_data_domain", default_domain_id, fn current ->
      normalize_simulation_process_data_domain(current, domain_ids)
    end)
    |> Map.update("health_poll_ms", default_health_poll_field(), fn
      "" -> default_health_poll_field()
      value -> value
    end)
  end

  defp normalize_simulation_slave_row(_row, domain_ids),
    do: empty_simulation_slave_row(domain_ids)

  defp empty_simulation_slave_row(domain_ids \\ []) do
    %{
      "name" => "",
      "driver" => "",
      "target_state" => "preop",
      "process_data_mode" => "none",
      "process_data_domain" => default_simulation_domain_id(domain_ids),
      "health_poll_ms" => default_health_poll_field()
    }
  end

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

  defp simulation_slaves(form) do
    normalize_simulation_config_form(form)["slaves"]
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

  defp stringify_form_map_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp simulation_driver_options do
    HardwareGateway.available_simulation_drivers()
  end

  defp simulation_driver_label(driver) do
    driver
    |> Module.split()
    |> List.last()
  end

  defp simulation_driver_value(driver) do
    driver
    |> to_string()
    |> String.trim_leading("Elixir.")
  end

  defp join_list([], fallback), do: fallback
  defp join_list(items, _fallback), do: Enum.join(items, ", ")
end
