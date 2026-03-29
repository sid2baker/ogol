defmodule Ogol.HMIWeb.SimulatorLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.{Bus, EventLog, HardwareConfig, HardwareContext, HardwareGateway}
  alias Ogol.HMIWeb.Components.StudioCell

  @event_limit 18
  @refresh_interval_ms 500

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
     |> assign(:cell_mode, :visual)
     |> assign(:events, EventLog.recent(@event_limit))
     |> assign(:simulation_config_form, HardwareGateway.default_ethercat_simulation_form())
     |> load_state()}
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
          %{config: config} -> config_form_from_config(config)
          _other -> socket.assigns.simulation_config_form
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
  def handle_event("set_simulator_mode", %{"mode" => raw_mode}, socket) do
    mode =
      case String.trim(raw_mode || "") do
        "source" -> :source
        _other -> :visual
      end

    {:noreply, assign(socket, :cell_mode, mode)}
  end

  def handle_event("change_simulation_config", %{"simulation_config" => params}, socket) do
    merged_form =
      merge_simulation_config_form(socket.assigns.simulation_config_form, params)

    {:noreply, assign(socket, :simulation_config_form, merged_form)}
  end

  def handle_event("add_simulation_slave", _params, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      {:noreply,
       update(socket, :simulation_config_form, fn form ->
         form
         |> normalize_simulation_config_form()
         |> update_in(["slaves"], fn slaves -> slaves ++ [empty_simulation_slave_row()] end)
       end)}
    else
      {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("remove_simulation_slave", %{"index" => index}, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      {:noreply,
       update(socket, :simulation_config_form, fn form ->
         form
         |> normalize_simulation_config_form()
         |> update_in(["slaves"], fn slaves -> remove_simulation_slave(slaves, index) end)
       end)}
    else
      {:noreply, deny_hardware_action(socket, :simulation_edit)}
    end
  end

  def handle_event("start_simulation", _params, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      config_form = normalize_simulation_config_form(socket.assigns.simulation_config_form)
      config_id = Map.get(config_form, "id", "draft")

      case HardwareGateway.start_simulation_config(config_form) do
        {:ok, %{config: config} = runtime} ->
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

  def handle_event("stop_simulation", _params, socket) do
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
    ~H"""
    <StudioCell.cell
      kicker="Simulator"
      title="Simulator Studio"
      summary="The simulator is its own Studio Cell now. Edit the ring visually or in source form, then explicitly start or stop the simulated runtime from the header actions."
      max_width="max-w-none"
      panel_class="border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]"
      data-test="simulator-studio"
    >
      <:actions>
        <button
          :if={@hardware_context.observed.source != :simulator}
          type="button"
          phx-click="start_simulation"
          phx-disable-with="Starting..."
          disabled={!simulation_allowed?(@hardware_context)}
          class={session_button_classes(:activate, simulation_allowed?(@hardware_context))}
          data-test="start-simulation"
        >
          Start simulation
        </button>
        <button
          :if={@hardware_context.observed.source == :simulator}
          type="button"
          phx-click="stop_simulation"
          disabled={!simulation_allowed?(@hardware_context)}
          class={session_button_classes(:deactivate, simulation_allowed?(@hardware_context))}
          data-test="simulation-stop-current"
        >
          Stop simulation
        </button>
      </:actions>

      <:modes>
        <StudioCell.toggle_button
          type="button"
          phx-click="set_simulator_mode"
          phx-value-mode="visual"
          active={@cell_mode == :visual}
          data-test="simulator-mode-visual"
        >
          Visual
        </StudioCell.toggle_button>
        <StudioCell.toggle_button
          type="button"
          phx-click="set_simulator_mode"
          phx-value-mode="source"
          active={@cell_mode == :source}
          data-test="simulator-mode-source"
        >
          Source
        </StudioCell.toggle_button>
      </:modes>

      <:output>
        <StudioCell.runtime_panel
          title={if(@hardware_context.observed.source == :simulator, do: "Simulation Runtime", else: "Simulation Draft")}
          summary={
            if @hardware_context.observed.source == :simulator do
              "Simulator is currently running."
            else
              "Edit the simulated ring here, then start the simulator from the generated configuration."
            end
          }
          class="border-white/10 bg-slate-900/80 text-slate-100"
        >
          <:fact label="Source" value={humanize_source(@hardware_context.observed.source)} />
          <:fact label="Config" value={@current_simulation_config_id || Map.get(@simulation_config_form, "id", "draft")} />
          <:fact label="Slaves" value={Integer.to_string(length(simulation_slaves(@simulation_config_form)))} />
          <:fact label="Drivers" value={Integer.to_string(simulation_driver_count(@simulation_config_form))} />
          <:fact
            label="Execution"
            value={
              simulation_execution_summary(
                @hardware_context,
                @running_simulation_config_id,
                @simulation_config_form
              )
            }
          />
        </StudioCell.runtime_panel>

        <div
          :if={@cell_mode == :visual and @hardware_context.observed.source == :simulator}
          class="grid gap-3 sm:grid-cols-2"
        >
          <.detail_panel title="Runtime" body="running" />
          <.detail_panel title="Config" body={@current_simulation_config_id || "draft"} />
          <.detail_panel
            title="Slaves"
            body={simulation_named_slave_summary(@simulation_config_form)}
          />
          <.detail_panel
            title="Drivers"
            body={simulation_driver_summary(@simulation_config_form)}
          />
        </div>

        <div
          :if={@cell_mode == :visual and @hardware_context.observed.source != :simulator}
          class="grid gap-3 sm:grid-cols-2"
        >
          <.detail_panel title="Draft" body={Map.get(@simulation_config_form, "id", "draft")} />
          <.detail_panel title="Label" body={Map.get(@simulation_config_form, "label", "unnamed")} />
          <.detail_panel title="Transport" body={simulation_transport_summary(@simulation_config_form)} />
          <.detail_panel title="Timing" body={simulation_timing_summary(@simulation_config_form)} />
          <.detail_panel title="Domains" body={simulation_domain_summary(@simulation_config_form)} />
          <.detail_panel title="Slave Posture" body={simulation_slave_posture_summary(@simulation_config_form)} />
          <.detail_panel title="Drivers" body={simulation_driver_summary(@simulation_config_form)} />
          <.detail_panel
            title="Execution"
            body={simulation_execution_summary(@hardware_context, @running_simulation_config_id, @simulation_config_form)}
          />
        </div>

        <StudioCell.banner
          :if={action_notice(@hardware_context, :simulation)}
          level={:warn}
          title="Simulation Notice"
          detail={action_notice(@hardware_context, :simulation)}
        />

        <StudioCell.banner
          :if={@hardware_feedback}
          level={hardware_feedback_level(@hardware_feedback.status)}
          title={@hardware_feedback.summary}
          detail={@hardware_feedback.detail}
          class="font-mono"
        />
      </:output>

      <div :if={@cell_mode == :source}>
        <.smart_cell_code
          title="Generated simulator cell"
          body={simulation_cell_code(@effective_simulation_config, @simulation_config_form)}
          data_test="simulation-cell-source"
        />
      </div>

      <div :if={@cell_mode == :visual and @hardware_context.observed.source == :simulator}>
        <div class="border border-cyan-300/15 bg-[#070b10] p-4" data-test="simulation-runtime-current">
          <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
            Current simulator state
          </p>
          <h4 class="mt-2 text-base font-semibold text-white">
            {@current_simulation_config_id || Map.get(@simulation_config_form, "id", "draft")}
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

      <div :if={@cell_mode == :visual and @hardware_context.observed.source != :simulator}>
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
    </StudioCell.cell>
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
      simulation_config_form: simulation_config_form,
      effective_simulation_config: effective_simulation_config,
      hardware_context: hardware_context,
      simulation_driver_options: simulation_driver_options(),
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

  defp simulation_allowed?(hardware_context) do
    hardware_context.mode.kind == :testing and
      hardware_context.mode.write_policy == :enabled and
      hardware_context.observed.source in [:none, :simulator]
  end

  defp action_notice(hardware_context, :simulation) do
    cond do
      simulation_allowed?(hardware_context) ->
        nil

      hardware_context.observed.source == :live ->
        "Simulation authoring is blocked while live hardware is connected. Use the EtherCAT tab to inspect the live bus, then return here once the live backend is detached."

      true ->
        "Simulation authoring is available in testing when no live hardware backend is active."
    end
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

  defp hardware_feedback_level(:pending), do: :info
  defp hardware_feedback_level(:ok), do: :good
  defp hardware_feedback_level(_other), do: :error

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

  defp session_button_classes(:activate, true) do
    "border border-emerald-400/25 bg-emerald-400/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-emerald-50 transition hover:border-emerald-300/40 hover:bg-emerald-300/15"
  end

  defp session_button_classes(:configure, true) do
    "border border-cyan-400/25 bg-cyan-400/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-cyan-50 transition hover:border-cyan-300/40 hover:bg-cyan-300/15"
  end

  defp session_button_classes(:deactivate, true) do
    "border border-amber-300/25 bg-amber-300/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-amber-50 transition hover:border-amber-200/40 hover:bg-amber-200/15"
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

  defp simulation_named_slave_summary(form) do
    form
    |> simulation_slaves()
    |> Enum.map(&Map.get(&1, "name", ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> join_list("unnamed")
  end

  defp simulation_driver_count(form) do
    form
    |> simulation_driver_values()
    |> length()
  end

  defp simulation_driver_summary(form) do
    form
    |> simulation_driver_values()
    |> Enum.map(&simulation_driver_value_label/1)
    |> join_list("choose drivers")
  end

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

  defp simulation_slave_posture_summary(form) do
    slaves = simulation_slaves(form)

    target_states =
      slaves
      |> Enum.map(&Map.get(&1, "target_state", "preop"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    process_modes =
      slaves
      |> Enum.map(&Map.get(&1, "process_data_mode", "none"))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    health_polls =
      slaves
      |> Enum.map(&Map.get(&1, "health_poll_ms", default_health_poll_field()))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.sort()

    "#{join_list(target_states, "preop")} · #{join_list(process_modes, "none")} · poll #{join_list(health_polls, default_health_poll_field())}ms"
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

  defp simulation_driver_values(form) do
    form
    |> simulation_slaves()
    |> Enum.map(&Map.get(&1, "driver", ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp simulation_driver_value_label(value) do
    value
    |> to_string()
    |> String.split(".")
    |> List.last()
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
