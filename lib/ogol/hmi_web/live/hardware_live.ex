defmodule Ogol.HMIWeb.HardwareLive do
  use Ogol.HMIWeb, :live_view

  alias Ogol.HMI.{Bus, EventLog, HardwareGateway}
  alias Ogol.HMIWeb.Components.StatusBadge

  @event_limit 18
  @refresh_interval_ms 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Bus.subscribe(Bus.events_topic())
      schedule_hardware_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Hardware Configuration")
     |> assign(:event_limit, @event_limit)
     |> assign(:hardware_feedback, nil)
     |> assign(:hardware_feedback_ref, nil)
     |> assign(:events, EventLog.recent(@event_limit))
     |> maybe_load_hardware_state()}
  end

  @impl true
  def handle_info({:event_logged, _notification}, socket) do
    {:noreply,
     socket
     |> assign(:events, EventLog.recent(@event_limit))
     |> maybe_load_hardware_state()}
  end

  def handle_info(:refresh_hardware, socket) do
    schedule_hardware_refresh()

    {:noreply, maybe_load_hardware_state(socket)}
  end

  def handle_info({:hardware_action_result, ref, feedback}, socket) do
    if socket.assigns.hardware_feedback_ref == ref do
      {:noreply,
       socket
       |> assign(:hardware_feedback_ref, nil)
       |> assign(:hardware_feedback, feedback)
       |> maybe_load_hardware_state()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("change_slave_config", %{"slave_config" => params}, socket) do
    slave_key = Map.get(params, "slave")

    {:noreply,
     update(socket, :slave_forms, fn forms ->
       Map.put(forms, slave_key, params)
     end)}
  end

  def handle_event("change_simulation_config", %{"simulation_config" => params}, socket) do
    {:noreply, assign(socket, :simulation_config_form, normalize_simulation_config_form(params))}
  end

  def handle_event("add_simulation_domain", _params, socket) do
    {:noreply,
     update(socket, :simulation_config_form, fn form ->
       form
       |> normalize_simulation_config_form()
       |> update_in(["domains"], fn domains -> domains ++ [empty_simulation_domain_row()] end)
     end)}
  end

  def handle_event("remove_simulation_domain", %{"index" => index}, socket) do
    {:noreply,
     update(socket, :simulation_config_form, fn form ->
       form
       |> normalize_simulation_config_form()
       |> update_in(["domains"], fn domains -> remove_simulation_domain(domains, index) end)
     end)}
  end

  def handle_event("add_simulation_slave", _params, socket) do
    {:noreply,
     update(socket, :simulation_config_form, fn form ->
       form
       |> normalize_simulation_config_form()
       |> update_in(["slaves"], fn slaves -> slaves ++ [empty_simulation_slave_row()] end)
     end)}
  end

  def handle_event("remove_simulation_slave", %{"index" => index}, socket) do
    {:noreply,
     update(socket, :simulation_config_form, fn form ->
       form
       |> normalize_simulation_config_form()
       |> update_in(["slaves"], fn slaves -> remove_simulation_slave(slaves, index) end)
     end)}
  end

  def handle_event("save_simulation_config", %{"simulation_config" => params}, socket) do
    case HardwareGateway.save_ethercat_simulation_config(params) do
      {:ok, config} ->
        {:noreply,
         socket
         |> assign(:simulation_config_form, config_form_from_config(config))
         |> assign(:hardware_feedback_ref, nil)
         |> assign(:hardware_feedback, config_feedback(:ok, config, nil))
         |> load_hardware_state()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:hardware_feedback_ref, nil)
         |> assign(:hardware_feedback, config_feedback(:error, params, reason))}
    end
  end

  def handle_event("start_saved_simulation", %{"config_id" => config_id}, socket) do
    ref = make_ref()

    dispatch_hardware_action_async(self(), ref, fn ->
      case HardwareGateway.start_simulation(config_id) do
        {:ok, runtime} -> {:ok, simulation_feedback(:ok, config_id, runtime)}
        {:error, reason} -> {:error, simulation_feedback(:error, config_id, reason)}
      end
    end)

    {:noreply,
     socket
     |> assign(:hardware_feedback_ref, ref)
     |> assign(:hardware_feedback, simulation_feedback(:pending, config_id, nil))}
  end

  def handle_event("save_slave_config", %{"slave_config" => params}, socket) do
    with {:ok, slave_name} <- parse_slave_name(Map.get(params, "slave")) do
      ref = make_ref()

      dispatch_hardware_action_async(self(), ref, fn ->
        case HardwareGateway.configure_ethercat_slave(slave_name, params) do
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
  end

  def handle_event("activate_ethercat", _params, socket) do
    ref = make_ref()

    dispatch_hardware_action_async(self(), ref, fn ->
      case HardwareGateway.activate_ethercat() do
        :ok -> {:ok, session_feedback(:ok, :activate, nil)}
        {:error, reason} -> {:error, session_feedback(:error, :activate, reason)}
      end
    end)

    {:noreply,
     socket
     |> assign(:hardware_feedback_ref, ref)
     |> assign(:hardware_feedback, session_feedback(:pending, :activate, nil))}
  end

  def handle_event("deactivate_ethercat", %{"target" => target}, socket) do
    case parse_deactivate_target(target) do
      {:ok, state_target} ->
        ref = make_ref()

        dispatch_hardware_action_async(self(), ref, fn ->
          case HardwareGateway.deactivate_ethercat(state_target) do
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
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="border border-white/10 bg-slate-950/85 px-4 py-4 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)] sm:px-5">
        <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
          <div>
            <.link navigate={~p"/"} class="font-mono text-[11px] uppercase tracking-[0.28em] text-slate-500 transition hover:text-slate-300">
              Overview
            </.link>
            <div class="mt-2 flex flex-wrap items-center gap-3">
              <h2 class="text-2xl font-semibold tracking-[0.04em] text-white">Hardware Configuration</h2>
              <StatusBadge.badge status={ethercat_health(@ethercat.state)} />
            </div>
            <p class="mt-2 max-w-4xl text-sm leading-6 text-slate-400">
              Configure protocol runtimes directly at the hardware boundary. This page is EtherCAT-first today, but the HMI model stays protocol-aware so other buses can slot in later without rewriting the shell.
            </p>
          </div>

          <div class="grid gap-2 sm:grid-cols-3">
            <.headline_stat label="Protocol" value="EtherCAT" />
            <.headline_stat label="Session" value={format_result(@ethercat.state)} />
            <.headline_stat label="Tracked Endpoints" value={length(@ethercat.hardware_snapshots)} />
          </div>
        </div>

        <div
          :if={@hardware_feedback}
          class={[
            "mt-4 flex flex-col gap-2 border px-3 py-3 sm:flex-row sm:items-start sm:justify-between",
            feedback_classes(@hardware_feedback.status)
          ]}
        >
          <div>
            <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">
              Hardware Path
            </p>
            <p class="mt-1 text-sm font-semibold text-white">{@hardware_feedback.summary}</p>
          </div>

          <p class="font-mono text-[11px] text-slate-300 sm:max-w-[38rem] sm:text-right">
            {@hardware_feedback.detail}
          </p>
        </div>
      </div>

      <section class="grid gap-4 xl:grid-cols-[minmax(0,1.25fr)_minmax(0,0.75fr)]">
        <div class="space-y-4">
          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4 sm:px-5">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Simulation Configs
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Saved hardware configurations</h3>
              <p class="mt-1 text-sm text-slate-400">
                Create a named, protocol-aware hardware config first. Then boot the EtherCAT simulator and master directly from that artifact.
              </p>
            </div>

            <div class="grid gap-4 p-3 sm:p-4 2xl:grid-cols-[minmax(0,1.1fr)_minmax(0,0.9fr)]">
              <form
                phx-change="change_simulation_config"
                phx-submit="save_simulation_config"
                data-test="simulation-config-form"
                class="grid gap-3 border border-white/8 bg-[#070b10] p-3"
              >
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

                  <label class="space-y-1.5">
                    <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Bind IP</span>
                    <input
                      type="text"
                      name="simulation_config[bind_ip]"
                      value={Map.get(@simulation_config_form, "bind_ip", "")}
                      class={input_classes()}
                    />
                  </label>

                  <label class="space-y-1.5">
                    <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Simulator IP</span>
                    <input
                      type="text"
                      name="simulation_config[simulator_ip]"
                      value={Map.get(@simulation_config_form, "simulator_ip", "")}
                      class={input_classes()}
                    />
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
                </div>

                <label class="space-y-1.5">
                  <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Frame Timeout ms</span>
                  <input
                    type="text"
                    name="simulation_config[frame_timeout_ms]"
                    value={Map.get(@simulation_config_form, "frame_timeout_ms", "")}
                    class={input_classes()}
                  />
                </label>

                <div class="space-y-2">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Domains</span>
                      <p class="mt-1 text-[11px] text-slate-500">
                        Define the EtherCAT runtime domains up front. Slave process-data registration selects from this list.
                      </p>
                    </div>

                    <button
                      type="button"
                      phx-click="add_simulation_domain"
                      class={session_button_classes(:configure, true)}
                      data-test="add-simulation-domain"
                    >
                      Add domain
                    </button>
                  </div>

                  <div class="space-y-3" data-test="simulation-config-domains">
                    <div
                      :for={{domain, index} <- Enum.with_index(simulation_domains(@simulation_config_form))}
                      class="grid gap-3 border border-white/8 bg-slate-950/55 p-3"
                      data-test={"simulation-config-domain-#{index}"}
                    >
                      <div class="flex items-center justify-between gap-3 border-b border-white/8 pb-2">
                        <p class="font-mono text-[11px] uppercase tracking-[0.22em] text-slate-400">
                          Domain {index + 1}
                        </p>

                        <button
                          :if={length(simulation_domains(@simulation_config_form)) > 1}
                          type="button"
                          phx-click="remove_simulation_domain"
                          phx-value-index={index}
                          class="border border-rose-400/25 bg-rose-400/10 px-2.5 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-rose-50 transition hover:border-rose-300/40 hover:bg-rose-300/15"
                          data-test={"remove-simulation-domain-#{index}"}
                        >
                          Remove
                        </button>
                      </div>

                      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Domain Id</span>
                          <input
                            type="text"
                            name={"simulation_config[domains][#{index}][id]"}
                            value={Map.get(domain, "id", "")}
                            class={input_classes()}
                          />
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Cycle us</span>
                          <input
                            type="text"
                            name={"simulation_config[domains][#{index}][cycle_time_us]"}
                            value={Map.get(domain, "cycle_time_us", "")}
                            class={input_classes()}
                          />
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Miss Threshold</span>
                          <input
                            type="text"
                            name={"simulation_config[domains][#{index}][miss_threshold]"}
                            value={Map.get(domain, "miss_threshold", "")}
                            class={input_classes()}
                          />
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Recovery Threshold</span>
                          <input
                            type="text"
                            name={"simulation_config[domains][#{index}][recovery_threshold]"}
                            value={Map.get(domain, "recovery_threshold", "")}
                            class={input_classes()}
                          />
                        </label>
                      </div>
                    </div>
                  </div>
                </div>

                <div class="space-y-2">
                  <div class="flex items-center justify-between gap-3">
                    <div>
                      <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Slaves</span>
                      <p class="mt-1 text-[11px] text-slate-500">
                        Configure each simulated device explicitly instead of editing a raw line format.
                      </p>
                    </div>

                    <button
                      type="button"
                      phx-click="add_simulation_slave"
                      class={session_button_classes(:configure, true)}
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
                          class="border border-rose-400/25 bg-rose-400/10 px-2.5 py-1 font-mono text-[10px] uppercase tracking-[0.22em] text-rose-50 transition hover:border-rose-300/40 hover:bg-rose-300/15"
                          data-test={"remove-simulation-slave-#{index}"}
                        >
                          Remove
                        </button>
                      </div>

                      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
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
                          <input
                            type="text"
                            name={"simulation_config[slaves][#{index}][driver]"}
                            value={Map.get(slave, "driver", "")}
                            class={input_classes()}
                          />
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Target State</span>
                          <select
                            name={"simulation_config[slaves][#{index}][target_state]"}
                            value={Map.get(slave, "target_state", "preop")}
                            class={input_classes()}
                          >
                            <option value="preop">preop</option>
                            <option value="op">op</option>
                          </select>
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Process Data</span>
                          <select
                            name={"simulation_config[slaves][#{index}][process_data_mode]"}
                            value={Map.get(slave, "process_data_mode", "none")}
                            class={input_classes()}
                          >
                            <option value="none">none</option>
                            <option value="all">all</option>
                          </select>
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Domain</span>
                          <select
                            name={"simulation_config[slaves][#{index}][process_data_domain]"}
                            value={Map.get(slave, "process_data_domain", "")}
                            class={input_classes()}
                          >
                            <option value="">default</option>
                            <option
                              :for={domain_id <- simulation_domain_ids(@simulation_config_form)}
                              value={domain_id}
                            >
                              {domain_id}
                            </option>
                          </select>
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Health Poll ms</span>
                          <input
                            type="text"
                            name={"simulation_config[slaves][#{index}][health_poll_ms]"}
                            value={Map.get(slave, "health_poll_ms", "")}
                            class={input_classes()}
                          />
                        </label>
                      </div>
                    </div>
                  </div>
                </div>

                <div class="flex flex-wrap items-center justify-between gap-2 border-t border-white/8 pt-3">
                  <span class="font-mono text-[10px] uppercase tracking-[0.22em] text-slate-500">
                    Stored in-memory for this runtime
                  </span>
                  <button
                    type="submit"
                    class={session_button_classes(:configure, true)}
                    data-test="save-simulation-config"
                  >
                    Save config
                  </button>
                </div>
              </form>

              <section class="border border-white/8 bg-[#070b10]">
                <div class="border-b border-white/8 px-4 py-3">
                  <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">
                    Saved Configurations
                  </p>
                </div>

                <div :if={@saved_configs == []} class="px-4 py-8 text-sm text-slate-400">
                  No saved hardware configs yet.
                </div>

                <div :if={@saved_configs != []} class="divide-y divide-white/8">
                  <article
                    :for={config <- @saved_configs}
                    class="px-4 py-3"
                  >
                    <div class="flex items-start justify-between gap-3">
                      <div class="min-w-0">
                        <div class="flex flex-wrap items-center gap-2">
                          <p class="text-sm font-semibold text-slate-100">{config.label}</p>
                          <StatusBadge.badge status={if(config.protocol == :ethercat, do: :healthy, else: :stale)} />
                        </div>
                        <p class="mt-1 font-mono text-[11px] text-slate-500">
                          {config.id} :: {config.protocol}
                        </p>
                        <p class="mt-2 text-[12px] text-slate-300">
                          {config_summary(config)}
                        </p>
                      </div>

                      <button
                        type="button"
                        phx-click="start_saved_simulation"
                        phx-value-config_id={config.id}
                        data-test={"start-simulation-#{config.id}"}
                        class={session_button_classes(:activate, true)}
                      >
                        Start simulation
                      </button>
                    </div>
                  </article>
                </div>
              </section>
            </div>
          </section>

          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4 sm:px-5">
              <div class="flex flex-col gap-4 xl:flex-row xl:items-end xl:justify-between">
                <div>
                  <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                    Protocol Runtime
                  </p>
                  <h3 class="mt-1 text-lg font-semibold text-white">EtherCAT session control</h3>
                  <p class="mt-1 text-sm text-slate-400">
                    Runtime state, diagnostics, and safe activation / retreat controls through the public EtherCAT API.
                  </p>
                </div>

                <div class="flex flex-wrap gap-2">
                  <button
                    type="button"
                    phx-click="activate_ethercat"
                    data-test="ethercat-activate"
                    disabled={!@ethercat.activatable?}
                    class={session_button_classes(:activate, @ethercat.activatable?)}
                  >
                    Activate
                  </button>
                  <button
                    type="button"
                    phx-click="deactivate_ethercat"
                    phx-value-target="safeop"
                    data-test="ethercat-deactivate-safeop"
                    disabled={!@ethercat.deactivatable?}
                    class={session_button_classes(:deactivate, @ethercat.deactivatable?)}
                  >
                    Retreat SafeOP
                  </button>
                  <button
                    type="button"
                    phx-click="deactivate_ethercat"
                    phx-value-target="preop"
                    data-test="ethercat-deactivate-preop"
                    disabled={!@ethercat.deactivatable?}
                    class={session_button_classes(:deactivate, @ethercat.deactivatable?)}
                  >
                    Retreat PREOP
                  </button>
                </div>
              </div>
            </div>

            <div class="grid gap-px bg-white/8 sm:grid-cols-2 xl:grid-cols-4">
              <.summary_panel label="Master State" value={format_result(@ethercat.state)} detail="public runtime state" />
              <.summary_panel label="Bus" value={format_result(@ethercat.bus)} detail="transport runtime" />
              <.summary_panel label="DC Lock" value={dc_lock_value(@ethercat.dc_status)} detail="distributed clocks" />
              <.summary_panel label="Domains" value={domain_count(@ethercat.domains)} detail="configured timing groups" />
              <.summary_panel label="Reference Clock" value={reference_clock_value(@ethercat.reference_clock)} detail="station clock source" />
              <.summary_panel label="Last Failure" value={failure_summary(@ethercat.last_failure)} detail="retained terminal fault" />
              <.summary_panel label="Slave Count" value={length(@ethercat.slaves)} detail="configured runtime slaves" />
              <.summary_panel label="Hardware Endpoints" value={length(@ethercat.hardware_snapshots)} detail="Ogol-side observed endpoints" />
            </div>
          </section>

          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4 sm:px-5">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Slave Configuration
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Per-slave PREOP configuration</h3>
              <p class="mt-1 text-sm text-slate-400">
                `configure_slave/2` is only valid while the EtherCAT session is held in PREOP. Configure process-data registration here, then activate when the ring is ready.
              </p>
            </div>

            <div class="p-3 sm:p-4">
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
                            value={form_value(@slave_forms, slave.name, "target_state")}
                            class={input_classes()}
                          >
                            <option value="op">op</option>
                            <option value="preop">preop</option>
                          </select>
                        </label>

                        <label class="space-y-1.5">
                          <span class="font-mono text-[10px] uppercase tracking-[0.26em] text-slate-500">Process Data</span>
                          <select
                            name="slave_config[process_data_mode]"
                            value={form_value(@slave_forms, slave.name, "process_data_mode")}
                            class={input_classes()}
                          >
                            <option value="none">none</option>
                            <option value="all">all</option>
                            <option value="signals">signals</option>
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
                          disabled={!@ethercat.configurable?}
                          class={session_button_classes(:configure, @ethercat.configurable?)}
                        >
                          Apply configuration
                        </button>
                      </div>
                    </form>
                  </div>
                </article>
              </div>
            </div>
          </section>
        </div>

        <aside class="space-y-4">
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
                Observed Endpoints
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Ogol-side EtherCAT telemetry</h3>
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

          <section class="overflow-hidden border border-white/10 bg-slate-950/85 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
            <div class="border-b border-white/10 px-4 py-4">
              <p class="font-mono text-[11px] font-medium uppercase tracking-[0.34em] text-amber-100/75">
                Recent Hardware Events
              </p>
              <h3 class="mt-1 text-lg font-semibold text-white">Configuration and runtime notices</h3>
            </div>

            <div class="max-h-[34rem] overflow-y-auto px-3 py-3">
              <div :if={@events == []} class="border border-dashed border-white/10 px-4 py-6 text-sm text-slate-400">
                No hardware-scoped notifications yet.
              </div>

              <div :if={@events != []} class="space-y-2">
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
            </div>
          </section>
        </aside>
      </section>
    </section>
    """
  end

  defp load_hardware_state(socket) do
    ethercat = HardwareGateway.ethercat_session()

    assign(socket,
      ethercat: ethercat,
      slave_forms: merge_slave_forms(socket.assigns[:slave_forms] || %{}, ethercat.slaves),
      simulation_config_form:
        socket.assigns[:simulation_config_form]
        |> Kernel.||(HardwareGateway.default_ethercat_simulation_form())
        |> normalize_simulation_config_form(),
      saved_configs: HardwareGateway.list_hardware_configs()
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

  defp config_feedback(:ok, config, _detail) do
    %{
      status: :ok,
      summary: "saved hardware config #{config.id}",
      detail: "#{config.label} is ready to boot as an EtherCAT simulation"
    }
  end

  defp config_feedback(:error, params, reason) do
    %{
      status: :error,
      summary: "hardware config save failed",
      detail: "#{Map.get(params, "id", "unknown")} :: #{inspect(reason)}"
    }
  end

  defp simulation_feedback(:pending, config_id, _detail) do
    %{
      status: :pending,
      summary: "starting simulation from #{config_id}",
      detail: "booting EtherCAT simulator and master from the saved hardware config"
    }
  end

  defp simulation_feedback(:ok, config_id, runtime) do
    %{
      status: :ok,
      summary: "simulation started from #{config_id}",
      detail:
        "state=#{inspect(runtime.state)} slaves=#{Enum.join(Enum.map(runtime.slaves, &to_string/1), ", ")}"
    }
  end

  defp simulation_feedback(:error, config_id, reason) do
    %{
      status: :error,
      summary: "simulation start failed for #{config_id}",
      detail: inspect(reason)
    }
  end

  defp invalid_feedback(action, reason) do
    %{status: :error, summary: "#{action} rejected by HMI", detail: inspect(reason)}
  end

  defp feedback_classes(:pending), do: "border-cyan-400/20 bg-cyan-400/8"
  defp feedback_classes(:ok), do: "border-emerald-400/20 bg-emerald-400/8"
  defp feedback_classes(:error), do: "border-rose-400/20 bg-rose-400/8"

  defp ethercat_health({:ok, :operational}), do: :running
  defp ethercat_health({:ok, :preop_ready}), do: :waiting
  defp ethercat_health({:ok, :deactivated}), do: :stopped
  defp ethercat_health({:ok, :activation_blocked}), do: :faulted
  defp ethercat_health({:ok, :recovering}), do: :recovering
  defp ethercat_health({:ok, :idle}), do: :stopped
  defp ethercat_health({:error, _reason}), do: :disconnected
  defp ethercat_health(_), do: :stale

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

  defp slave_driver(%{info: {:ok, info}}), do: format_term(info[:driver], "unknown")
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
          :hardware_session_control_applied,
          :hardware_session_control_failed
        ]
    end)
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

  defp config_summary(config) do
    spec = config.spec
    slave_count = length(spec[:slaves] || [])
    domain_count = length(spec[:domains] || [])

    "#{slave_count} slave(s), #{domain_count} domain(s), bind=#{format_ip(spec[:bind_ip])}, sim=#{format_ip(spec[:simulator_ip])}"
  end

  defp config_form_from_config(config) do
    config
    |> Map.get(:meta, %{})
    |> Map.get(:form, %{})
    |> then(&Map.merge(HardwareGateway.default_ethercat_simulation_form(), &1))
    |> normalize_simulation_config_form()
  end

  defp normalize_simulation_config_form(form) when is_map(form) do
    form
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
    |> Map.update("domains", [empty_simulation_domain_row()], fn domains ->
      case normalize_simulation_domain_rows(domains) do
        [] -> [empty_simulation_domain_row()]
        rows -> rows
      end
    end)
    |> Map.update("slaves", [empty_simulation_slave_row()], fn slaves ->
      case normalize_simulation_slave_rows(slaves) do
        [] -> [empty_simulation_slave_row()]
        rows -> rows
      end
    end)
  end

  defp normalize_simulation_config_form(_form) do
    HardwareGateway.default_ethercat_simulation_form()
  end

  defp normalize_simulation_slave_rows(rows) when is_list(rows) do
    Enum.map(rows, &normalize_simulation_slave_row/1)
  end

  defp normalize_simulation_slave_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} ->
      case Integer.parse(to_string(index)) do
        {int, ""} -> int
        _ -> 999_999
      end
    end)
    |> Enum.map(fn {_index, row} -> normalize_simulation_slave_row(row) end)
  end

  defp normalize_simulation_slave_rows(_rows), do: []

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
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value || ""))
    end)
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

  defp normalize_simulation_slave_row(row) when is_map(row) do
    row
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), to_string(value || ""))
    end)
    |> Map.put_new("name", "")
    |> Map.put_new("driver", "")
    |> Map.put_new("target_state", "preop")
    |> Map.put_new("process_data_mode", "none")
    |> Map.put_new("process_data_domain", "")
    |> Map.put_new("health_poll_ms", "")
  end

  defp normalize_simulation_slave_row(_row), do: empty_simulation_slave_row()

  defp empty_simulation_slave_row do
    %{
      "name" => "",
      "driver" => "",
      "target_state" => "preop",
      "process_data_mode" => "none",
      "process_data_domain" => "",
      "health_poll_ms" => ""
    }
  end

  defp simulation_domains(form) do
    normalize_simulation_config_form(form)["domains"]
  end

  defp simulation_domain_ids(form) do
    form
    |> simulation_domains()
    |> Enum.map(&Map.get(&1, "id", ""))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp simulation_slaves(form) do
    normalize_simulation_config_form(form)["slaves"]
  end

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

  defp format_ip({a, b, c, d}), do: Enum.join([a, b, c, d], ".")
  defp format_ip(other), do: inspect(other)

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)

  defp headline_stat(assigns) do
    ~H"""
    <div class="border border-white/10 bg-slate-950/70 px-3 py-2">
      <p class="font-mono text-[10px] uppercase tracking-[0.28em] text-slate-500">{@label}</p>
      <p class="mt-1 text-sm font-semibold text-slate-100">{@value}</p>
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
