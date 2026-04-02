defmodule OgolWeb.Studio.SimulatorLive do
  use OgolWeb, :live_view

  alias Ogol.Hardware.Config.EtherCAT, as: EtherCATConfig
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias OgolWeb.Live.SessionSync
  alias OgolWeb.Studio.Cell, as: StudioCell
  alias OgolWeb.Studio.Revision, as: StudioRevision
  alias Ogol.Session

  @event_limit 18
  @refresh_interval_ms 500
  @default_config_id "ethercat_demo"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = Session.subscribe(:events)
      schedule_refresh()
    end

    {:ok,
     socket
     |> assign(:page_title, "Simulator Studio")
     |> assign(
       :page_summary,
       "Start or stop the simulator runtime from the current hardware config, then inspect the derived config source without editing a second copy."
     )
     |> assign(:hmi_mode, :studio)
     |> assign(:hmi_nav, :studio_home)
     |> assign(:hardware_feedback, nil)
     |> assign(:hardware_feedback_ref, nil)
     |> assign(:events, Session.recent_events(@event_limit))
     |> assign(:simulation_config_id, @default_config_id)
     |> StudioRevision.subscribe()
     |> load_state()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    _ = params

    {:noreply,
     socket
     |> StudioRevision.apply_param(params)
     |> load_simulation()
     |> load_state()
     |> maybe_assign_revision_target_feedback()}
  end

  @impl true
  def handle_info({:event_logged, _notification}, socket) do
    {:noreply,
     socket
     |> assign(:events, Session.recent_events(@event_limit))
     |> load_state()}
  end

  def handle_info({:operations, operations}, socket) do
    {:noreply,
     socket
     |> StudioRevision.apply_operations(operations)
     |> load_simulation()
     |> load_state()}
  end

  def handle_info({:runtime_updated, _action, _reply}, socket) do
    {:noreply,
     socket
     |> load_simulation()
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
          %{config: %EtherCATConfig{} = config} ->
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
  def handle_event("request_transition", %{"transition" => "start_simulation"}, socket) do
    if simulation_allowed?(socket.assigns.hardware_context) do
      config_input = simulation_runtime_input(socket)
      config_id = simulation_runtime_input_id(config_input, socket.assigns.simulation_config_id)

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
          case Session.stop_simulation(config_id) do
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
    <section class="grid gap-5">
      <.feedback_banner feedback={@hardware_feedback} />

      <section
        class="app-panel border-white/10 bg-slate-950/85 px-5 py-5 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]"
        data-test="simulator-studio"
      >
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
              Simulator
            </p>
            <h3 class="mt-1 text-lg font-semibold text-white">Derived from current hardware config</h3>
            <p class="mt-1 max-w-3xl text-sm text-slate-300">
              This page no longer owns simulator source. Edit the hardware config on the Hardware tab, then use this page to start or stop the simulator runtime from that config.
            </p>
          </div>

          <div class="flex flex-wrap gap-2">
            <button
              :if={@hardware_context.observed.source != :simulator}
              type="button"
              phx-click="request_transition"
              phx-value-transition="start_simulation"
              phx-disable-with="Starting..."
              class={session_button_classes(:activate, simulation_allowed?(@hardware_context))}
              data-test="start-simulation"
              disabled={!simulation_allowed?(@hardware_context)}
            >
              Start simulation
            </button>

            <button
              :if={@hardware_context.observed.source == :simulator}
              type="button"
              phx-click="request_transition"
              phx-value-transition="stop_simulation"
              class={session_button_classes(:deactivate, simulation_allowed?(@hardware_context))}
              data-test="simulation-stop-current"
              disabled={!simulation_allowed?(@hardware_context)}
            >
              Stop simulation
            </button>

            <.link
              navigate={StudioRevision.path_with_revision(~p"/studio/hardware/ethercat", @studio_selected_revision)}
              class="app-button-secondary"
            >
              Edit Hardware Config
            </.link>
          </div>
        </div>

        <div
          :if={@hardware_context.observed.source == :simulator}
          class="mt-4 border border-cyan-300/15 bg-[#070b10] p-4"
          data-test="simulation-runtime-current"
        >
          <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
            Current simulator state
          </p>
          <h4 class="mt-2 text-base font-semibold text-white">
            {@current_simulation_config_id || @simulation_config_id}
          </h4>
          <p class="mt-2 text-sm text-slate-300">
            The simulator is already running from the current hardware config.
          </p>
        </div>

        <div class="mt-4 grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <.detail_panel title="Config" body={@simulation_config_id} />
          <.detail_panel title="Transport" body={simulation_transport_summary(@simulation_config_form)} />
          <.detail_panel title="Timing" body={simulation_timing_summary(@simulation_config_form)} />
          <.detail_panel title="Domains" body={simulation_domain_summary(@simulation_config_form)} />
          <.detail_panel title="Execution" body={simulation_execution_summary(@hardware_context, @running_simulation_config_id, @simulation_config_form)} />
        </div>
      </section>

      <section class="app-panel border-white/10 bg-slate-950/85 px-5 py-5 shadow-[0_30px_80px_-48px_rgba(0,0,0,0.95)]">
        <div class="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="font-mono text-[10px] uppercase tracking-[0.26em] text-cyan-100/75">
              Current Hardware Config
            </p>
            <p class="mt-1 text-sm text-slate-300">
              Read-only source preview of the config the simulator derives from.
            </p>
          </div>

          <p class="font-mono text-[10px] uppercase tracking-[0.22em] text-slate-500">
            Edit on Hardware tab
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
    """
  end

  defp load_state(socket) do
    ethercat = Session.ethercat_session()
    events = socket.assigns[:events] || Session.recent_events(@event_limit)

    simulation_config_form =
      socket.assigns[:simulation_config_form]
      |> Kernel.||(Session.default_ethercat_simulation_form())
      |> normalize_simulation_config_form()

    current_hardware = SessionSync.hardware_config_model(socket, :ethercat)

    {effective_simulation_config, hardware_config_source} =
      case {current_hardware, SessionSync.fetch_hardware_config(socket, :ethercat)} do
        {%EtherCATConfig{} = config, %{source: source}} when is_binary(source) ->
          {config, source}

        {%EtherCATConfig{} = config, _draft} ->
          {config, HardwareConfigSource.to_source(config)}

        _other ->
          case Session.preview_ethercat_simulation_config(simulation_config_form) do
            {:ok, config} ->
              {config, HardwareConfigSource.to_source(config)}

            {:error, reason} ->
              {nil, invalid_hardware_config_source(simulation_config_form, reason)}
          end
      end

    hardware_context = Session.build_hardware_context(ethercat, events, [], mode: :testing)
    running_simulation_config_id = running_simulation_config_id(events, hardware_context)

    assign(socket,
      ethercat: ethercat,
      simulation_config_form: simulation_config_form,
      effective_simulation_config: effective_simulation_config,
      hardware_config_source: hardware_config_source,
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

  defp load_simulation(socket) do
    config = selected_hardware_config(socket)
    socket = SessionSync.refresh(socket)

    socket
    |> assign(
      :simulation_config_id,
      (SessionSync.hardware_config_model(socket, :ethercat) || config).id
    )
    |> assign(
      :simulation_config_form,
      config_form_from_config(SessionSync.hardware_config_model(socket, :ethercat) || config)
    )
  end

  defp simulation_allowed?(hardware_context) when is_map(hardware_context) do
    hardware_context.mode.kind == :testing and
      hardware_context.mode.write_policy == :enabled and
      hardware_context.observed.source in [:none, :simulator]
  end

  defp invalid_hardware_config_source(form, reason) do
    config_id =
      form
      |> Map.get("id", @default_config_id)
      |> to_string()

    """
    # Hardware config preview is invalid
    # config_id: #{config_id}
    # reason: #{inspect(reason)}
    """
    |> String.trim()
  end

  defp ensure_simulation_config(socket) do
    case SessionSync.hardware_config_model(socket, :ethercat) do
      %EtherCATConfig{} = config ->
        config

      _other ->
        create_simulation_config()
    end
  end

  defp create_simulation_config do
    form = Session.default_ethercat_simulation_form()
    {:ok, config} = Session.preview_ethercat_simulation_config(form)
    %Session.Workspace.SourceDraft{} = Session.put_hardware_config(:ethercat, config)
    config
  end

  defp selected_hardware_config(socket), do: ensure_simulation_config(socket)

  defp simulation_runtime_input(socket) do
    SessionSync.hardware_config_model(socket, :ethercat) ||
      socket.assigns.simulation_config_form
      |> normalize_simulation_config_form()
      |> Map.put("id", socket.assigns.simulation_config_id)
  end

  defp simulation_runtime_input_id(%EtherCATConfig{id: id}, _fallback) when is_binary(id), do: id

  defp simulation_runtime_input_id(input, fallback) when is_map(input),
    do: Map.get(input, "id", fallback)

  defp simulation_runtime_input_id(_input, fallback), do: fallback

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
        "This simulator page is showing the shared workspace session after loading the selected revision into it."
    }
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

  defp feedback_tone(%{status: status}) when status in [:ok, :pending, :info], do: :info
  defp feedback_tone(%{status: status}) when status in [:warning, :warn], do: :warning
  defp feedback_tone(_feedback), do: :error

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

  defp session_button_classes(_kind, false) do
    "cursor-not-allowed border border-white/10 bg-slate-900/60 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-slate-600"
  end

  defp session_button_classes(:activate, true) do
    "border border-emerald-400/25 bg-emerald-400/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-emerald-50 transition hover:border-emerald-300/40 hover:bg-emerald-300/15"
  end

  defp session_button_classes(:deactivate, true) do
    "border border-amber-400/25 bg-amber-400/10 px-3 py-2 font-mono text-[11px] uppercase tracking-[0.22em] text-amber-50 transition hover:border-amber-300/40 hover:bg-amber-300/15"
  end

  defp simulation_transport_summary(form) do
    form = normalize_simulation_config_form(form)

    case Map.get(form, "transport", "udp") do
      "raw" ->
        "raw socket via #{Map.get(form, "primary_interface", "unassigned")}"

      "redundant" ->
        primary = Map.get(form, "primary_interface", "unassigned")
        secondary = Map.get(form, "secondary_interface", "unassigned")
        "redundant #{primary} -> #{secondary}"

      _other ->
        "bind #{Map.get(form, "bind_ip", "127.0.0.1")} -> sim #{Map.get(form, "simulator_ip", "127.0.0.2")}"
    end
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
    |> Session.ethercat_form_from_config()
    |> normalize_simulation_config_form()
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

  defp empty_simulation_slave_row(domain_ids) do
    %{
      "name" => "",
      "driver" => "",
      "target_state" => "preop",
      "process_data_mode" => "none",
      "process_data_domain" => default_simulation_domain_id(domain_ids),
      "health_poll_ms" => default_health_poll_field()
    }
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

  defp join_list([], fallback), do: fallback
  defp join_list(items, _fallback), do: Enum.join(items, ", ")
end
