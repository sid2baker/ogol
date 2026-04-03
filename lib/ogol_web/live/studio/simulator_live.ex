defmodule OgolWeb.Studio.SimulatorLive do
  use OgolWeb, :live_view

  alias EtherCAT.Backend
  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATConfig
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.Session
  alias OgolWeb.Live.SessionSync
  alias OgolWeb.Studio.Cell, as: StudioCell

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
       "Derived EtherCAT simulator control over the current workspace hardware config, separate from topology startup."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :simulator)
     |> assign(:ethercat_session, %{})
     |> assign(:hardware_config, nil)
     |> assign(:hardware_config_source, "")
     |> assign(:simulator_warning, nil)
     |> assign(:simulator_feedback, nil)
     |> load_state()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, load_state(socket)}
  end

  @impl true
  def handle_info({:operations, operations}, socket) do
    {:noreply,
     socket
     |> SessionSync.apply_operations(operations)
     |> load_state()}
  end

  def handle_info({:runtime_updated, _action, _reply}, socket) do
    {:noreply, load_state(socket)}
  end

  def handle_info(:refresh_simulator, socket) do
    schedule_refresh()
    {:noreply, load_state(socket)}
  end

  @impl true
  def handle_event("request_transition", %{"transition" => "start_simulation"}, socket) do
    case socket.assigns.hardware_config do
      %EtherCATConfig{} = config ->
        case Session.start_simulation_config(config) do
          {:ok, runtime} ->
            {:noreply,
             socket
             |> assign(:simulator_feedback, start_feedback(:ok, config.id, runtime))
             |> load_state()}

          {:error, reason} ->
            {:noreply,
             assign(socket, :simulator_feedback, start_feedback(:error, config.id, reason))}
        end

      _other ->
        {:noreply, assign(socket, :simulator_feedback, missing_config_feedback())}
    end
  end

  def handle_event("request_transition", %{"transition" => "stop_simulation"}, socket) do
    config_id = socket.assigns.hardware_config && socket.assigns.hardware_config.id

    case Session.stop_simulation(config_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:simulator_feedback, stop_feedback(:ok, config_id))
         |> load_state()}

      {:error, reason} ->
        {:noreply, assign(socket, :simulator_feedback, stop_feedback(:error, config_id, reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= cond do %>
      <% @hardware_config -> %>
        <section class="grid gap-5" data-test="simulator-studio">
          <section class="app-panel px-5 py-5">
            <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
              <div class="max-w-3xl">
                <p class="app-kicker">Simulator</p>
                <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
                  Derived from current EtherCAT config
                </h2>
                <p class="mt-3 text-sm leading-6 text-[var(--app-text-muted)]">
                  This page owns simulator runtime control. Edit EtherCAT on the Hardware page, and
                  start or stop the derived simulator here.
                </p>
              </div>

              <div class="flex flex-wrap gap-2">
                <button
                  :if={!simulator_running?(@ethercat_session)}
                  type="button"
                  phx-click="request_transition"
                  phx-value-transition="start_simulation"
                  phx-disable-with="Starting..."
                  class="app-button"
                  data-test="start-simulation"
                >
                  Start simulation
                </button>

                <button
                  :if={simulator_running?(@ethercat_session)}
                  type="button"
                  phx-click="request_transition"
                  phx-value-transition="stop_simulation"
                  class="app-button-secondary"
                  data-test="simulation-stop-current"
                >
                  Stop simulation
                </button>

                <.link navigate={~p"/studio/hardware/ethercat"} class="app-button-secondary">
                  Open Hardware Config
                </.link>
              </div>
            </div>

            <div :if={@simulator_feedback} class="mt-4">
              <StudioCell.notice
                tone={feedback_tone(@simulator_feedback)}
                title={@simulator_feedback.summary}
                message={@simulator_feedback.detail}
              />
            </div>

            <div class="mt-4" data-test="simulator-runtime-status">
              <StudioCell.notice
                tone={runtime_notice_tone(@ethercat_session)}
                title={runtime_notice_title(@ethercat_session)}
                message={runtime_notice_message(@ethercat_session)}
              />
            </div>

            <div class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-6">
              <.detail_panel title="Config" body={@hardware_config.id} />
              <.detail_panel title="Transport" body={transport_summary(@hardware_config)} />
              <.detail_panel title="Timing" body={timing_summary(@hardware_config)} />
              <.detail_panel title="Domains" body={domain_summary(@hardware_config)} />
              <.detail_panel title="Slaves" body={slave_summary(@hardware_config)} />
              <.detail_panel title="Master" body={master_summary(@ethercat_session)} />
            </div>
          </section>

          <section class="grid gap-5 xl:grid-cols-[18rem_minmax(0,1fr)]">
            <section class="app-panel px-5 py-5">
              <p class="app-kicker">Domains</p>
              <div class="mt-4 grid gap-3">
                <.domain_card
                  :for={domain <- @hardware_config.domains}
                  domain={domain}
                  data_test={"simulator-domain-#{domain.id}"}
                />
              </div>
            </section>

            <section class="app-panel px-5 py-5">
              <p class="app-kicker">Slaves</p>
              <div class="mt-4 grid gap-3">
                <.slave_card
                  :for={slave <- @hardware_config.slaves}
                  slave={slave}
                  data_test={"simulator-slave-#{slave.name}"}
                />
              </div>
            </section>
          </section>

          <section class="app-panel px-5 py-5">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p class="app-kicker">Source</p>
                <p class="mt-1 text-sm text-[var(--app-text-muted)]">
                  Canonical generated EtherCAT config for the current workspace.
                </p>
              </div>

              <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-subtle)]">
                Read-only
              </p>
            </div>

            <div class="mt-4">
              <.smart_cell_code
                title="Generated hardware config"
                body={@hardware_config_source}
                data_test="simulation-config-source"
              />
            </div>
          </section>
        </section>

      <% @hardware_config_source != "" -> %>
        <section class="grid gap-5" data-test="simulator-studio">
          <section class="app-panel px-5 py-5">
            <StudioCell.notice
              tone={:warning}
              title="Simulator projection unavailable"
              message={@simulator_warning}
            />
          </section>

          <section class="app-panel px-5 py-5">
            <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
              <div>
                <p class="app-kicker">Source</p>
                <p class="mt-1 text-sm text-[var(--app-text-muted)]">
                  The current EtherCAT config source is available, but it no longer maps cleanly to
                  the derived simulator projection.
                </p>
              </div>

              <.link navigate={~p"/studio/hardware/ethercat"} class="app-button-secondary">
                Open Hardware Config
              </.link>
            </div>

            <div class="mt-4">
              <.smart_cell_code
                title="Current hardware config source"
                body={@hardware_config_source}
                data_test="simulation-config-source"
              />
            </div>
          </section>
        </section>

      <% true -> %>
        <section class="app-panel px-5 py-5" data-test="simulator-studio-empty">
          <p class="app-kicker">No EtherCAT Config</p>
          <h2 class="mt-2 text-2xl font-semibold tracking-tight text-[var(--app-text)]">
            Simulator view needs an EtherCAT config
          </h2>
          <p class="mt-3 max-w-3xl text-sm leading-6 text-[var(--app-text-muted)]">
            Author the current workspace EtherCAT config on the Hardware page first. This page only
            visualizes the simulator shape derived from that config.
          </p>

          <div class="mt-4">
            <.link navigate={~p"/studio/hardware/ethercat"} class="app-button-secondary">
              Open Hardware Config
            </.link>
          </div>
        </section>
    <% end %>
    """
  end

  defp load_state(socket) do
    ethercat_session = Session.ethercat_session()
    hardware_draft = SessionSync.fetch_hardware_config(socket, :ethercat)
    hardware_config = SessionSync.hardware_config_model(socket, :ethercat)

    {hardware_config_source, simulator_warning} =
      case {hardware_config, hardware_draft} do
        {%EtherCATConfig{}, %{source: source}} when is_binary(source) ->
          {source, nil}

        {%EtherCATConfig{} = config, _other} ->
          {HardwareConfigSource.to_source(config), nil}

        {nil, %{source: source}} when is_binary(source) ->
          {source, "Current EtherCAT source cannot be visualized as a derived simulator view."}

        _other ->
          {"", nil}
      end

    assign(socket,
      ethercat_session: ethercat_session,
      hardware_config: hardware_config,
      hardware_config_source: hardware_config_source,
      simulator_warning: simulator_warning
    )
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_simulator, @refresh_interval_ms)
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

  attr(:domain, :map, required: true)
  attr(:data_test, :string, default: nil)

  defp domain_card(assigns) do
    ~H"""
    <section class="border border-white/8 bg-slate-900/70 px-4 py-4" data-test={@data_test}>
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="font-medium text-[var(--app-text)]">{@domain.id}</p>
          <p class="mt-1 text-sm text-[var(--app-text-muted)]">
            cycle {@domain.cycle_time_us}us
          </p>
        </div>

        <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-subtle)]">
          domain
        </p>
      </div>

      <div class="mt-4 grid gap-3 sm:grid-cols-2">
        <.detail_panel title="Miss Threshold" body={Integer.to_string(@domain.miss_threshold)} />
        <.detail_panel
          title="Recovery Threshold"
          body={Integer.to_string(@domain.recovery_threshold)}
        />
      </div>
    </section>
    """
  end

  attr(:slave, :map, required: true)
  attr(:data_test, :string, default: nil)

  defp slave_card(assigns) do
    ~H"""
    <section class="border border-white/8 bg-slate-900/70 px-4 py-4" data-test={@data_test}>
      <div class="flex items-start justify-between gap-3">
        <div>
          <p class="font-medium text-[var(--app-text)]">{@slave.name}</p>
          <p class="mt-1 text-sm text-[var(--app-text-muted)]">{driver_label(@slave.driver)}</p>
        </div>

        <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-[var(--app-text-subtle)]">
          {String.upcase(to_string(@slave.target_state))}
        </p>
      </div>

      <div class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <.detail_panel title="Process Data" body={process_data_summary(@slave.process_data)} />
        <.detail_panel title="Health Poll" body={"#{@slave.health_poll_ms || "off"}"} />
        <.detail_panel title="Aliases" body={alias_summary(@slave.aliases)} />
        <.detail_panel title="Config" body={slave_config_summary(@slave.config)} />
      </div>
    </section>
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

  defp runtime_summary(
         %{
           simulator_status: %{lifecycle: :running, backend: backend}
         } = session
       ) do
    "simulator #{backend_summary(backend)}; master #{format_state(master_state(session))}"
  end

  defp runtime_summary(session) do
    "simulator not running; master #{format_state(master_state(session))}"
  end

  defp master_summary(session), do: format_state(master_state(session))

  defp master_state(%{state: {:ok, state}}), do: state
  defp master_state(%{state: {:error, :not_started}}), do: :stopped
  defp master_state(%{state: {:error, reason}}), do: {:error, reason}
  defp master_state(%{state: state}), do: state
  defp master_state(_session), do: :idle

  defp simulator_running?(%{simulator_status: %{lifecycle: :running}}), do: true
  defp simulator_running?(_session), do: false

  defp feedback_tone(%{status: status}) when status in [:ok, :pending, :info], do: :info
  defp feedback_tone(%{status: status}) when status in [:warning, :warn], do: :warning
  defp feedback_tone(_feedback), do: :error

  defp missing_config_feedback do
    %{
      status: :error,
      summary: "Simulation start failed",
      detail: "Define a current EtherCAT hardware config first."
    }
  end

  defp start_feedback(:ok, config_id, runtime) do
    %{
      status: :ok,
      summary: "simulation started from #{config_id}",
      detail:
        "simulator port=#{runtime.port} slaves=#{Enum.join(Enum.map(runtime.slaves, &to_string/1), ", ")}"
    }
  end

  defp start_feedback(:error, config_id, reason) do
    %{
      status: :error,
      summary: "simulation start failed for #{config_id}",
      detail: inspect(reason)
    }
  end

  defp stop_feedback(:ok, config_id) do
    %{
      status: :ok,
      summary: "simulation stopped for #{config_id || "ethercat"}",
      detail: "the simulator runtime is stopped"
    }
  end

  defp stop_feedback(:error, config_id, reason) do
    %{
      status: :error,
      summary: "simulation stop failed for #{config_id || "ethercat"}",
      detail: inspect(reason)
    }
  end

  defp format_state(state) when is_atom(state), do: state |> Atom.to_string() |> String.upcase()
  defp format_state({:error, reason}), do: "ERROR #{inspect(reason)}"
  defp format_state(state), do: to_string(state)

  defp transport_summary(%EtherCATConfig{} = config) do
    case EtherCATConfig.transport_mode(config) do
      :raw ->
        "raw #{EtherCATConfig.primary_interface(config) || "unassigned"}"

      :redundant ->
        primary = EtherCATConfig.primary_interface(config) || "unassigned"
        secondary = EtherCATConfig.secondary_interface(config) || "unassigned"
        "redundant #{primary} -> #{secondary}"

      :udp ->
        "bind #{format_ip(EtherCATConfig.bind_ip(config))} -> sim #{format_ip(EtherCATConfig.simulator_ip(config))}"
    end
  end

  defp timing_summary(%EtherCATConfig{} = config) do
    "stable #{EtherCATConfig.scan_stable_ms(config)}ms · poll #{EtherCATConfig.scan_poll_ms(config)}ms · frame #{EtherCATConfig.frame_timeout_ms(config)}ms"
  end

  defp domain_summary(%EtherCATConfig{} = config) do
    ids = Enum.map(config.domains, &to_string(&1.id))
    "#{length(ids)} domain(s): #{join_list(ids, "none")}"
  end

  defp slave_summary(%EtherCATConfig{} = config) do
    names = Enum.map(config.slaves, &to_string(&1.name))
    "#{length(names)} slave(s): #{join_list(names, "none")}"
  end

  defp process_data_summary(:none), do: "none"
  defp process_data_summary({:all, domain_id}), do: "all -> #{domain_id}"
  defp process_data_summary({mode, domain_id}), do: "#{mode} -> #{domain_id}"
  defp process_data_summary(other), do: inspect(other)

  defp alias_summary(aliases) when aliases == %{}, do: "none"

  defp alias_summary(aliases) when is_map(aliases) do
    aliases
    |> Enum.map(fn {signal, endpoint} -> "#{signal} -> #{endpoint}" end)
    |> Enum.join(", ")
  end

  defp alias_summary(_aliases), do: "none"

  defp slave_config_summary(config) when config == %{}, do: "default"
  defp slave_config_summary(config) when is_map(config), do: "#{map_size(config)} key(s)"
  defp slave_config_summary(_config), do: "custom"

  defp driver_label(driver) when is_atom(driver) do
    driver
    |> Module.split()
    |> List.last()
  end

  defp driver_label(driver), do: inspect(driver)

  defp backend_summary(%Backend.Udp{port: port}), do: "udp port #{port}"

  defp backend_summary(%Backend.Raw{interface: interface}),
    do: "raw #{interface || "unassigned"}"

  defp backend_summary(%Backend.Redundant{} = backend) do
    "#{backend_summary(backend.primary)} -> #{backend_summary(backend.secondary)}"
  end

  defp backend_summary(backend), do: inspect(backend)

  defp format_ip(nil), do: "unassigned"
  defp format_ip({a, b, c, d}), do: Enum.join([a, b, c, d], ".")
  defp format_ip(value), do: to_string(value)

  defp join_list([], fallback), do: fallback
  defp join_list(items, _fallback), do: Enum.join(items, ", ")
end
