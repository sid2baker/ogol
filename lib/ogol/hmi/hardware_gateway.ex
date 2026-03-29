defmodule Ogol.HMI.HardwareGateway do
  @moduledoc false

  alias EtherCAT.Backend
  alias EtherCAT.Diagnostics
  alias EtherCAT.Master
  alias EtherCAT.Master.Status, as: MasterStatus
  alias EtherCAT.Provisioning
  alias EtherCAT.Scan
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias EtherCAT.Slave.Config, as: SlaveConfig

  alias Ogol.HMI.{
    EthercatRuntimeOwner,
    HardwareConfig,
    HardwareConfigStore,
    HardwareReleaseStore,
    HardwareSupportSnapshot,
    HardwareSupportSnapshotStore,
    RuntimeNotifier,
    SnapshotStore
  }

  @default_health_poll_ms SlaveConfig.default_health_poll_ms()
  @default_bind_ip "127.0.0.1"
  @default_simulator_ip "127.0.0.2"
  @default_domain_id "main"
  @default_cycle_time_us 1_000
  @default_scan_stable_ms 20
  @default_scan_poll_ms 10
  @default_frame_timeout_ms 20

  @spec protocols() :: [map()]
  def protocols do
    [
      %{
        id: :ethercat,
        label: "EtherCAT",
        available?: Code.ensure_loaded?(EtherCAT),
        configurable?: true
      }
    ]
  end

  @spec list_hardware_configs() :: [HardwareConfig.t()]
  def list_hardware_configs do
    HardwareConfigStore.list_configs()
  end

  @spec available_simulation_drivers() :: [module()]
  def available_simulation_drivers do
    _ = Application.load(:ethercat)

    :ethercat
    |> Application.spec(:modules)
    |> List.wrap()
    |> Enum.filter(&simulation_driver?/1)
    |> Enum.sort()
  end

  @spec default_ethercat_simulation_form() :: map()
  def default_ethercat_simulation_form do
    %{
      "id" => "ethercat_demo",
      "label" => "EtherCAT Demo Ring",
      "transport" => "udp",
      "bind_ip" => @default_bind_ip,
      "simulator_ip" => @default_simulator_ip,
      "primary_interface" => "",
      "secondary_interface" => "",
      "domains" => default_domain_rows(),
      "scan_stable_ms" => Integer.to_string(@default_scan_stable_ms),
      "scan_poll_ms" => Integer.to_string(@default_scan_poll_ms),
      "frame_timeout_ms" => Integer.to_string(@default_frame_timeout_ms),
      "slaves" => default_slave_rows()
    }
  end

  @spec available_raw_interfaces() :: [String.t()]
  def available_raw_interfaces do
    case Application.get_env(:ogol, :ethercat_available_interfaces) do
      interfaces when is_list(interfaces) ->
        normalize_configured_interfaces(interfaces)

      _other ->
        discover_raw_interfaces()
    end
  end

  @spec save_ethercat_simulation_config(map()) :: {:ok, HardwareConfig.t()} | {:error, term()}
  def save_ethercat_simulation_config(params) when is_map(params) do
    with {:ok, config} <- normalize_ethercat_simulation_config(params) do
      :ok = HardwareConfigStore.put_config(config)

      RuntimeNotifier.emit(:hardware_config_saved,
        source: __MODULE__,
        payload: %{protocol: :ethercat, config_id: config.id, label: config.label},
        meta: %{bus: :ethercat, config_id: config.id}
      )

      {:ok, config}
    end
  end

  @spec preview_ethercat_simulation_config(map()) :: {:ok, HardwareConfig.t()} | {:error, term()}
  def preview_ethercat_simulation_config(params) when is_map(params) do
    normalize_ethercat_simulation_config(params)
  end

  @spec start_simulation_config(map()) :: {:ok, map()} | {:error, term()}
  def start_simulation_config(params) when is_map(params) do
    with {:ok, config} <- normalize_ethercat_simulation_config(params),
         {:ok, runtime} <- start_ethercat_simulator(config) do
      {:ok, Map.put(runtime, :config, config)}
    end
  end

  @spec preview_ethercat_hardware_config(map()) :: {:ok, HardwareConfig.t()} | {:error, term()}
  def preview_ethercat_hardware_config(attrs \\ %{}) when is_map(attrs) do
    build_captured_ethercat_config(attrs)
  end

  @spec capture_ethercat_hardware_config(map()) :: {:ok, HardwareConfig.t()} | {:error, term()}
  def capture_ethercat_hardware_config(attrs \\ %{}) when is_map(attrs) do
    with {:ok, config} <- build_captured_ethercat_config(attrs) do
      :ok = HardwareConfigStore.put_config(config)

      RuntimeNotifier.emit(:hardware_config_saved,
        source: __MODULE__,
        payload: %{
          protocol: :ethercat,
          config_id: config.id,
          label: config.label,
          captured: true
        },
        meta: %{bus: :ethercat, config_id: config.id, captured: true}
      )

      {:ok, config}
    end
  end

  @spec start_simulation(binary()) :: {:ok, map()} | {:error, term()}
  def start_simulation(config_id) when is_binary(config_id) do
    case HardwareConfigStore.get_config(config_id) do
      %HardwareConfig{protocol: :ethercat} = config ->
        start_ethercat_simulator(config)

      %HardwareConfig{} = config ->
        {:error, {:unsupported_protocol, config.protocol}}

      nil ->
        {:error, :unknown_hardware_config}
    end
  end

  @spec start_ethercat_master(map()) :: {:ok, map()} | {:error, term()}
  def start_ethercat_master(params) when is_map(params) do
    with {:ok, config} <- normalize_ethercat_simulation_config(params),
         {:ok, %{state: state}} <- EthercatRuntimeOwner.start_master(config.spec) do
      RuntimeNotifier.emit(:hardware_session_control_applied,
        source: __MODULE__,
        payload: %{
          protocol: :ethercat,
          action: :start_master,
          config_id: config.id,
          label: config.label
        },
        meta: %{bus: :ethercat, config_id: config.id}
      )

      {:ok,
       %{
         config: config,
         config_id: config.id,
         state: state,
         slaves: Enum.map(config.spec.slaves, & &1.name)
       }}
    else
      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_session_control_failed,
          source: __MODULE__,
          payload: %{protocol: :ethercat, action: :start_master, reason: reason},
          meta: %{bus: :ethercat}
        )

        error
    end
  end

  @spec stop_simulation(binary() | nil) :: :ok | {:error, term()}
  def stop_simulation(config_id \\ nil)

  def stop_simulation(config_id) when is_binary(config_id) or is_nil(config_id) do
    case EthercatRuntimeOwner.stop_all() do
      :ok ->
        RuntimeNotifier.emit(:hardware_simulation_stopped,
          source: __MODULE__,
          payload: %{protocol: :ethercat, config_id: config_id},
          meta: %{bus: :ethercat, config_id: config_id}
        )

        :ok

      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_session_control_failed,
          source: __MODULE__,
          payload: %{protocol: :ethercat, action: :stop_simulation, reason: reason},
          meta: %{bus: :ethercat, config_id: config_id}
        )

        error
    end
  end

  @spec stop_ethercat_master() :: :ok | {:error, term()}
  def stop_ethercat_master do
    case EthercatRuntimeOwner.stop_master() do
      :ok ->
        RuntimeNotifier.emit(:hardware_session_control_applied,
          source: __MODULE__,
          payload: %{protocol: :ethercat, action: :stop_master},
          meta: %{bus: :ethercat}
        )

        :ok

      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_session_control_failed,
          source: __MODULE__,
          payload: %{protocol: :ethercat, action: :stop_master, reason: reason},
          meta: %{bus: :ethercat}
        )

        error
    end
  end

  @spec scan_ethercat_master_form(map()) :: {:ok, map()} | {:error, term()}
  def scan_ethercat_master_form(params) when is_map(params) do
    current_form = normalize_form_map(params)

    with {:ok, config} <- normalize_ethercat_simulation_config(current_form),
         {:ok, scanned_form} <- scanned_master_form(config, current_form) do
      {:ok, normalize_form_map(scanned_form)}
    end
  end

  @spec ethercat_session() :: map()
  def ethercat_session do
    master_status = master_status()
    simulator_status = simulator_status()
    domains = configured_domains(master_status)
    domain_ids = domain_ids(domains)
    slave_summaries = configured_slave_summaries(master_status)

    %{
      protocol: :ethercat,
      label: "EtherCAT",
      protocols: protocols(),
      master_status: master_status,
      simulator_status: simulator_status,
      state: master_state(master_status),
      configurable?: master_configurable?(master_status),
      activatable?: master_activatable?(master_status),
      deactivatable?: master_deactivatable?(master_status),
      bus: master_bus(master_status),
      dc_status: master_dc_status(master_status),
      reference_clock: master_reference_clock(master_status),
      last_failure: master_last_failure(master_status),
      domains: domains,
      aggregate_snapshot: master_snapshot(master_status),
      slaves: build_slave_rows(slave_summaries, domain_ids),
      hardware_snapshots: ethercat_hardware_snapshots()
    }
  end

  @spec ethercat_master_running?() :: boolean()
  def ethercat_master_running? do
    case master_status() do
      %MasterStatus{lifecycle: lifecycle} when lifecycle not in [:stopped, :idle] -> true
      _status -> false
    end
  end

  @spec configure_ethercat_slave(atom(), map()) :: {:ok, SlaveConfig.t()} | {:error, term()}
  def configure_ethercat_slave(slave_name, params)
      when is_atom(slave_name) and is_map(params) do
    with {:ok, spec} <- normalize_ethercat_slave_config(slave_name, params),
         :ok <- Provisioning.configure_slave(slave_name, spec) do
      RuntimeNotifier.emit(:hardware_configuration_applied,
        source: __MODULE__,
        payload: %{protocol: :ethercat, slave: slave_name, spec: summarize_spec(spec)},
        meta: %{bus: :ethercat, endpoint_id: slave_name}
      )

      {:ok, spec}
    else
      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_configuration_failed,
          source: __MODULE__,
          payload: %{protocol: :ethercat, slave: slave_name, params: params, reason: reason},
          meta: %{bus: :ethercat, endpoint_id: slave_name}
        )

        error
    end
  end

  @spec activate_ethercat() :: :ok | {:error, term()}
  def activate_ethercat do
    case Provisioning.activate() do
      :ok ->
        RuntimeNotifier.emit(:hardware_session_control_applied,
          source: __MODULE__,
          payload: %{protocol: :ethercat, action: :activate},
          meta: %{bus: :ethercat}
        )

        :ok

      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_session_control_failed,
          source: __MODULE__,
          payload: %{protocol: :ethercat, action: :activate, reason: reason},
          meta: %{bus: :ethercat}
        )

        error
    end
  end

  @spec deactivate_ethercat(:safeop | :preop) :: :ok | {:error, term()}
  def deactivate_ethercat(target) when target in [:safeop, :preop] do
    case Provisioning.deactivate(target) do
      :ok ->
        RuntimeNotifier.emit(:hardware_session_control_applied,
          source: __MODULE__,
          payload: %{protocol: :ethercat, action: :deactivate, target: target},
          meta: %{bus: :ethercat}
        )

        :ok

      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_session_control_failed,
          source: __MODULE__,
          payload: %{protocol: :ethercat, action: :deactivate, target: target, reason: reason},
          meta: %{bus: :ethercat}
        )

        error
    end
  end

  @spec default_ethercat_slave_form(atom()) :: map()
  def default_ethercat_slave_form(slave_name) when is_atom(slave_name) do
    domain_ids = current_domain_ids()

    case Diagnostics.slave_info(slave_name) do
      {:ok, info} -> config_form_defaults(slave_name, info, domain_ids)
      {:error, _reason} -> config_form_defaults(slave_name, %{}, domain_ids)
    end
  end

  @spec list_support_snapshots() :: [HardwareSupportSnapshot.t()]
  def list_support_snapshots do
    HardwareSupportSnapshotStore.list_snapshots()
  end

  @spec get_support_snapshot(binary()) :: HardwareSupportSnapshot.t() | nil
  def get_support_snapshot(id) when is_binary(id) do
    HardwareSupportSnapshotStore.get_snapshot(id)
  end

  def current_candidate_release do
    HardwareReleaseStore.current_candidate()
  end

  def current_armed_release do
    HardwareReleaseStore.current_armed_release()
  end

  def candidate_vs_armed_diff do
    HardwareReleaseStore.candidate_vs_armed_diff()
  end

  def release_history do
    HardwareReleaseStore.release_history()
  end

  def rollback_armed_release(version) when is_binary(version) do
    HardwareReleaseStore.rollback_to_release(version)
  end

  def promote_candidate_config(%HardwareConfig{} = config) do
    {:ok, HardwareReleaseStore.promote_candidate(config)}
  end

  def arm_candidate_release do
    HardwareReleaseStore.arm_candidate()
  end

  @spec capture_runtime_snapshot(map()) :: {:ok, HardwareSupportSnapshot.t()}
  def capture_runtime_snapshot(attrs \\ %{}) when is_map(attrs) do
    capture_support_snapshot(Map.put(attrs, :kind, :runtime))
  end

  @spec capture_support_snapshot(map()) :: {:ok, HardwareSupportSnapshot.t()}
  def capture_support_snapshot(attrs \\ %{}) when is_map(attrs) do
    kind = attrs[:kind] || :support
    captured_at = System.system_time(:millisecond)
    context = Map.get(attrs, :context, %{})
    ethercat = Map.get(attrs, :ethercat, %{})
    events = Map.get(attrs, :events, [])
    saved_configs = Map.get(attrs, :saved_configs, [])

    snapshot = %HardwareSupportSnapshot{
      id: support_snapshot_id(kind, captured_at),
      kind: kind,
      captured_at: captured_at,
      summary: %{
        mode: context_mode(context, :kind),
        source: context_observed(context, :source),
        state: context_summary(context, :state),
        write_policy: context_mode(context, :write_policy),
        slave_count: length(Map.get(ethercat, :slaves, [])),
        event_count: length(events),
        saved_config_count: length(saved_configs)
      },
      payload: %{
        context: context,
        ethercat: sanitize_ethercat(ethercat),
        events: Enum.take(events, -40),
        saved_configs:
          Enum.map(saved_configs, fn config ->
            %{
              id: config.id,
              label: config.label,
              protocol: config.protocol,
              updated_at: config.updated_at
            }
          end)
      }
    }

    :ok = HardwareSupportSnapshotStore.put_snapshot(snapshot)
    {:ok, snapshot}
  end

  defp start_ethercat_simulator(%HardwareConfig{} = config) do
    spec = config.spec

    with {:ok, %{port: port}} <- EthercatRuntimeOwner.start_simulator(spec) do
      RuntimeNotifier.emit(:hardware_simulation_started,
        source: __MODULE__,
        payload: %{
          protocol: :ethercat,
          config_id: config.id,
          label: config.label,
          slave_count: length(spec.slaves),
          config: config
        },
        meta: %{bus: :ethercat, config_id: config.id}
      )

      {:ok,
       %{
         config_id: config.id,
         port: port,
         slaves: Enum.map(spec.slaves, & &1.name)
       }}
    else
      {:error, reason} = error ->
        RuntimeNotifier.emit(:hardware_simulation_failed,
          source: __MODULE__,
          payload: %{protocol: :ethercat, config_id: config.id, reason: reason},
          meta: %{bus: :ethercat, config_id: config.id}
        )

        error
    end
  end

  defp build_slave_rows({:ok, slave_summaries}, domain_ids) when is_list(slave_summaries) do
    Enum.map(slave_summaries, fn summary ->
      info = Diagnostics.slave_info(summary.name)
      snapshot = EtherCAT.snapshot(summary.name)

      %{
        name: summary.name,
        station: summary.station,
        pid: summary.pid,
        fault: summary.fault,
        info: info,
        snapshot: snapshot,
        hardware_snapshot: SnapshotStore.get_hardware(:ethercat, summary.name),
        form_defaults:
          case info do
            {:ok, slave_info} -> config_form_defaults(summary.name, slave_info, domain_ids)
            {:error, _reason} -> config_form_defaults(summary.name, %{}, domain_ids)
          end
      }
    end)
    |> Enum.sort_by(&to_string(&1.name))
  end

  defp build_slave_rows(slave_summaries, domain_ids) when is_list(slave_summaries) do
    build_slave_rows({:ok, slave_summaries}, domain_ids)
  end

  defp build_slave_rows(_error, _domain_ids), do: []

  defp ethercat_hardware_snapshots do
    SnapshotStore.list_hardware()
    |> Enum.filter(&(&1.bus == :ethercat))
  end

  defp master_status do
    case Master.status() do
      %MasterStatus{} = status -> status
      {:error, _reason} -> MasterStatus.stopped()
    end
  end

  defp simulator_status do
    case Simulator.status() do
      {:ok, %SimulatorStatus{} = status} -> status
      {:error, _reason} -> SimulatorStatus.stopped()
    end
  end

  defp master_state(%MasterStatus{lifecycle: :stopped}), do: {:error, :not_started}
  defp master_state(%MasterStatus{lifecycle: lifecycle}), do: {:ok, lifecycle}

  defp master_configurable?(%MasterStatus{lifecycle: :preop_ready}), do: true
  defp master_configurable?(_status), do: false

  defp master_activatable?(%MasterStatus{lifecycle: lifecycle})
       when lifecycle in [:preop_ready, :deactivated],
       do: true

  defp master_activatable?(_status), do: false

  defp master_deactivatable?(%MasterStatus{lifecycle: lifecycle})
       when lifecycle in [:operational, :activation_blocked, :recovering],
       do: true

  defp master_deactivatable?(_status), do: false

  defp master_bus(%MasterStatus{} = status), do: {:ok, status.bus_status}

  defp master_dc_status(%MasterStatus{} = status), do: {:ok, status.dc_status}

  defp master_reference_clock(%MasterStatus{reference_clock: %{}} = status),
    do: {:ok, status.reference_clock}

  defp master_reference_clock(%MasterStatus{dc_status: %{configured?: false}}),
    do: {:error, :dc_disabled}

  defp master_reference_clock(%MasterStatus{}), do: {:error, :no_reference_clock}

  defp master_last_failure(%MasterStatus{} = status), do: {:ok, status.last_failure}

  defp master_snapshot(%MasterStatus{lifecycle: :stopped}), do: {:error, :not_started}
  defp master_snapshot(%MasterStatus{}), do: EtherCAT.snapshot()

  defp configured_domains(%MasterStatus{} = status) do
    {:ok,
     Enum.map(status.configured_domains, fn domain ->
       {domain.id, domain.live_cycle_time_us || domain.configured_cycle_time_us, domain.pid}
     end)}
  end

  defp configured_slave_summaries(%MasterStatus{} = status) do
    Enum.map(status.configured_slaves, fn slave ->
      %{
        name: slave.name,
        station: slave.station,
        pid: slave.pid,
        fault: slave.fault
      }
    end)
  end

  defp current_domain_ids do
    master_status()
    |> configured_domains()
    |> domain_ids()
  end

  defp normalize_ethercat_simulation_config(params) do
    params =
      params
      |> stringify_map_keys()
      |> apply_simulation_defaults()

    with {:ok, config_id} <- parse_config_id(Map.get(params, "id")),
         {:ok, label} <- parse_label(Map.get(params, "label"), config_id),
         {:ok, transport} <- parse_transport(Map.get(params, "transport")),
         {:ok, transport_fields} <- parse_transport_fields(transport, params),
         {:ok, domains} <-
           parse_simulation_domains(
             Map.get(params, "domains"),
             Map.get(params, "domain_id"),
             Map.get(params, "domain_cycle_us")
           ),
         {:ok, scan_stable_ms} <-
           parse_positive_int(Map.get(params, "scan_stable_ms"), :scan_stable_ms),
         {:ok, scan_poll_ms} <- parse_positive_int(Map.get(params, "scan_poll_ms"), :scan_poll_ms),
         {:ok, frame_timeout_ms} <-
           parse_positive_int(Map.get(params, "frame_timeout_ms"), :frame_timeout_ms),
         {:ok, slaves} <-
           parse_simulation_slaves(
             Map.get(params, "slaves"),
             Map.get(params, "slave_lines"),
             domains
           ) do
      now = System.system_time(:millisecond)
      form = normalized_simulation_form(params, domains, slaves)

      {:ok,
       %HardwareConfig{
         id: config_id,
         protocol: :ethercat,
         label: label,
         inserted_at: existing_inserted_at(config_id, now),
         updated_at: now,
         spec:
           Map.merge(transport_fields, %{
             transport: transport,
             domains: domains,
             scan_stable_ms: scan_stable_ms,
             scan_poll_ms: scan_poll_ms,
             frame_timeout_ms: frame_timeout_ms,
             slaves: slaves
           }),
         meta: %{form: form}
       }}
    end
  end

  defp scanned_master_form(%HardwareConfig{} = config, current_form) do
    case master_status() do
      %MasterStatus{lifecycle: lifecycle} = status when lifecycle not in [:stopped, :idle] ->
        scanned_form_from_master_status(status, current_form)

      _other ->
        with {:ok, backend} <- scan_backend_for_spec(config.spec) do
          case Scan.scan(backend) do
            {:ok, scan_result} ->
              {:ok, scanned_form_from_scan_result(scan_result, current_form)}

            {:error, {:backend_in_use, _active_backend}} ->
              scanned_form_from_master_status(master_status(), current_form)

            {:error, _reason} = error ->
              error
          end
        end
    end
  end

  defp scan_backend_for_spec(spec) do
    case spec.transport do
      :udp ->
        case simulator_status() do
          %SimulatorStatus{lifecycle: :running, backend: %Backend.Udp{} = backend} ->
            {:ok, %{backend | bind_ip: spec.bind_ip}}

          %SimulatorStatus{lifecycle: :running, backend: %Backend.Raw{} = backend} ->
            {:ok, backend}

          %SimulatorStatus{lifecycle: :running, backend: %Backend.Redundant{} = backend} ->
            {:ok, backend}

          _other ->
            {:ok, %Backend.Udp{host: spec.simulator_ip, bind_ip: spec.bind_ip}}
        end

      :raw ->
        {:ok, %Backend.Raw{interface: spec.primary_interface}}

      :redundant ->
        {:ok,
         %Backend.Redundant{
           primary: %Backend.Raw{interface: spec.primary_interface},
           secondary: %Backend.Raw{interface: spec.secondary_interface}
         }}
    end
  end

  defp scanned_form_from_master_status(%MasterStatus{lifecycle: lifecycle} = status, current_form)
       when lifecycle not in [:stopped, :idle] do
    domains =
      status.configured_domains
      |> Enum.map(&domain_form_row_from_status/1)
      |> case do
        [] -> normalize_simulation_domain_rows(Map.get(current_form, "domains"))
        rows -> rows
      end

    slaves =
      status.configured_slaves
      |> Enum.map(&slave_form_row_from_status/1)
      |> case do
        [] ->
          normalize_simulation_slave_rows(
            Map.get(current_form, "slaves"),
            domain_ids({:ok, domains})
          )

        rows ->
          rows
      end

    {:ok, current_form |> Map.put("domains", domains) |> Map.put("slaves", slaves)}
  end

  defp scanned_form_from_master_status(_status, _current_form), do: {:error, :no_live_hardware}

  defp scanned_form_from_scan_result(%Scan.Result{} = result, current_form) do
    domain_ids =
      domain_ids({:ok, normalize_simulation_domain_rows(Map.get(current_form, "domains"))})

    slaves =
      result.discovered_slaves
      |> Enum.with_index()
      |> Enum.map(fn {slave, index} ->
        scan_slave_form_row(slave, index, current_form, domain_ids)
      end)

    current_form
    |> Map.put("slaves", slaves)
  end

  defp domain_form_row_from_status(domain) do
    %{
      "id" => to_string(domain.id),
      "cycle_time_us" => Integer.to_string(domain.configured_cycle_time_us),
      "miss_threshold" => "1000",
      "recovery_threshold" => "3"
    }
  end

  defp slave_form_row_from_status(slave) do
    domain_id =
      case slave.process_data do
        {:all, domain} -> to_string(domain)
        _other -> @default_domain_id
      end

    %{
      "name" => to_string(slave.name),
      "driver" => format_module(slave.driver),
      "target_state" => Atom.to_string(slave.target_state || :op),
      "process_data_mode" => process_data_mode_value(slave.process_data),
      "process_data_domain" => domain_id,
      "health_poll_ms" => health_poll_field(slave.health_poll_ms, slave.target_state || :op)
    }
  end

  defp scan_slave_form_row(slave, index, current_form, domain_ids) do
    current_row =
      current_form
      |> Map.get("slaves", [])
      |> normalize_simulation_slave_rows(domain_ids)
      |> Enum.at(index, %{})

    driver = scan_driver(slave.identity)
    default_name = default_scan_slave_name(driver, index)

    {process_data_mode, process_data_domain} = default_slave_process_data(driver, domain_ids)

    %{
      "name" => scan_slave_name(current_row, default_name),
      "driver" => format_module(driver),
      "target_state" => scan_target_state(slave.al_state),
      "process_data_mode" => process_data_mode,
      "process_data_domain" => process_data_domain,
      "health_poll_ms" => default_health_poll_field(:op)
    }
  end

  defp scan_driver(%{vendor_id: vendor_id, product_code: product_code}) do
    available_simulation_drivers()
    |> Enum.find(EtherCAT.Driver.Default, fn driver ->
      function_exported?(driver, :identity, 0) and
        match?(%{vendor_id: ^vendor_id, product_code: ^product_code}, driver.identity())
    end)
  end

  defp scan_driver(_identity), do: EtherCAT.Driver.Default

  defp default_scan_slave_name(EtherCAT.Driver.EK1100, _index), do: "coupler"
  defp default_scan_slave_name(EtherCAT.Driver.EL1809, _index), do: "inputs"
  defp default_scan_slave_name(EtherCAT.Driver.EL2809, _index), do: "outputs"
  defp default_scan_slave_name(_driver, index), do: "slave_#{index + 1}"

  defp scan_slave_name(current_row, default_name) do
    case Map.get(current_row, "name", "") |> String.trim() do
      "" -> default_name
      name -> name
    end
  end

  defp scan_target_state(:op), do: "op"
  defp scan_target_state(:safeop), do: "op"
  defp scan_target_state(:preop), do: "op"
  defp scan_target_state(_state), do: "op"

  defp normalize_ethercat_slave_config(slave_name, params) do
    with {:ok, driver} <- parse_driver(Map.get(params, "driver")),
         {:ok, process_data} <-
           parse_process_data(driver, params, current_domain_ids()),
         {:ok, target_state} <- parse_target_state(Map.get(params, "target_state")),
         {:ok, health_poll_ms} <-
           parse_health_poll_ms(Map.get(params, "health_poll_ms"), target_state) do
      {:ok,
       %SlaveConfig{
         name: slave_name,
         driver: driver,
         config: %{},
         process_data: process_data,
         target_state: target_state,
         health_poll_ms: health_poll_ms
       }}
    end
  end

  defp parse_driver(value) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, :missing_driver}
    else
      module =
        trimmed
        |> String.trim_leading("Elixir.")
        |> then(&Module.concat([&1]))

      if Code.ensure_loaded?(module) do
        {:ok, module}
      else
        {:error, :unknown_driver}
      end
    end
  end

  defp parse_driver(_value), do: {:error, :missing_driver}

  defp parse_process_data(driver, params, domain_ids) do
    case Map.get(params, "process_data_mode", "none") do
      "none" ->
        {:ok, :none}

      "all" ->
        with {:ok, domain_id} <-
               parse_domain_id(Map.get(params, "process_data_domain"), domain_ids) do
          {:ok, {:all, domain_id}}
        end

      "signals" ->
        parse_signal_assignments(
          Map.get(params, "process_data_signals", ""),
          signal_names(driver),
          domain_ids
        )

      other ->
        {:error, {:invalid_process_data_mode, other}}
    end
  end

  defp parse_target_state(value) when value in ["op", "preop"] do
    {:ok, String.to_atom(value)}
  end

  defp parse_target_state(_value), do: {:error, :invalid_target_state}

  defp parse_health_poll_ms(nil, target_state), do: {:ok, default_health_poll_ms(target_state)}

  defp parse_health_poll_ms(value, target_state) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, default_health_poll_ms(target_state)}

      value when value in ["off", "disable", "disabled", "nil"] ->
        {:ok, nil}

      trimmed ->
        case Integer.parse(trimmed) do
          {int, ""} when int > 0 -> {:ok, int}
          _ -> {:error, :invalid_health_poll_ms}
        end
    end
  end

  defp parse_health_poll_ms(_value, _target_state), do: {:error, :invalid_health_poll_ms}

  defp parse_domain_id(value, domain_ids) when is_binary(value) do
    trimmed = String.trim(value)

    if trimmed == "" do
      {:error, :missing_domain_id}
    else
      domain =
        Enum.find(domain_ids, fn domain_id ->
          to_string(domain_id) == trimmed
        end)

      if domain do
        {:ok, domain}
      else
        {:error, {:unknown_domain, trimmed}}
      end
    end
  end

  defp parse_domain_id(_value, _domain_ids), do: {:error, :missing_domain_id}

  defp parse_signal_assignments(raw, allowed_signals, domain_ids) when is_binary(raw) do
    entries =
      raw
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if entries == [] do
      {:error, :missing_signal_assignments}
    else
      Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
        with {:ok, signal_name, domain_id} <-
               parse_signal_assignment(entry, allowed_signals, domain_ids) do
          {:cont, {:ok, acc ++ [{signal_name, domain_id}]}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp parse_signal_assignment(entry, allowed_signals, domain_ids) do
    separator =
      cond do
        String.contains?(entry, "@") -> "@"
        String.contains?(entry, ":") -> ":"
        true -> nil
      end

    case separator && String.split(entry, separator, parts: 2) do
      [signal_name, domain_name] ->
        with {:ok, signal_atom} <- parse_signal_name(signal_name, allowed_signals),
             {:ok, domain_atom} <- parse_domain_id(domain_name, domain_ids) do
          {:ok, signal_atom, domain_atom}
        end

      _ ->
        {:error, {:invalid_signal_assignment, entry}}
    end
  end

  defp parse_signal_name(value, allowed_signals) when is_binary(value) do
    trimmed = String.trim(value)

    signal =
      Enum.find(allowed_signals, fn signal_name ->
        to_string(signal_name) == trimmed
      end)

    if signal do
      {:ok, signal}
    else
      {:error, {:unknown_signal, trimmed}}
    end
  end

  defp parse_config_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :missing_config_id}

      Regex.match?(~r/\A[a-zA-Z0-9_\-]+\z/, trimmed) ->
        {:ok, trimmed}

      true ->
        {:error, :invalid_config_id}
    end
  end

  defp parse_config_id(_value), do: {:error, :missing_config_id}

  defp parse_label(value, config_id) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, humanize_id(config_id)}
      trimmed -> {:ok, trimmed}
    end
  end

  defp parse_label(_value, config_id), do: {:ok, humanize_id(config_id)}

  defp parse_transport(value) when is_binary(value) do
    case String.trim(value) do
      "udp" -> {:ok, :udp}
      "raw" -> {:ok, :raw}
      "redundant" -> {:ok, :redundant}
      _other -> {:error, :invalid_transport}
    end
  end

  defp parse_transport(_value), do: {:error, :invalid_transport}

  defp parse_transport_fields(:udp, params) do
    with {:ok, bind_ip} <- parse_ip(Map.get(params, "bind_ip"), :bind_ip),
         {:ok, simulator_ip} <- parse_ip(Map.get(params, "simulator_ip"), :simulator_ip) do
      {:ok,
       %{
         bind_ip: bind_ip,
         simulator_ip: simulator_ip,
         primary_interface: nil,
         secondary_interface: nil
       }}
    end
  end

  defp parse_transport_fields(:raw, params) do
    with {:ok, primary_interface} <-
           parse_interface(Map.get(params, "primary_interface"), :missing_primary_interface) do
      {:ok,
       %{
         bind_ip: nil,
         simulator_ip: nil,
         primary_interface: primary_interface,
         secondary_interface: nil
       }}
    end
  end

  defp parse_transport_fields(:redundant, params) do
    with {:ok, primary_interface} <-
           parse_interface(Map.get(params, "primary_interface"), :missing_primary_interface),
         {:ok, secondary_interface} <-
           parse_interface(Map.get(params, "secondary_interface"), :missing_secondary_interface),
         :ok <- ensure_distinct_interfaces(primary_interface, secondary_interface) do
      {:ok,
       %{
         bind_ip: nil,
         simulator_ip: nil,
         primary_interface: primary_interface,
         secondary_interface: secondary_interface
       }}
    end
  end

  defp parse_ip(value, _field) when is_binary(value) do
    case value |> String.trim() |> String.to_charlist() |> :inet.parse_address() do
      {:ok, ip} -> {:ok, ip}
      {:error, _reason} -> {:error, :invalid_ip}
    end
  end

  defp parse_ip(_value, _field), do: {:error, :invalid_ip}

  defp parse_interface(value, error_key) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error_key}
      interface -> {:ok, interface}
    end
  end

  defp parse_interface(_value, error_key), do: {:error, error_key}

  defp ensure_distinct_interfaces(primary_interface, secondary_interface)
       when primary_interface == secondary_interface do
    {:error, :duplicate_redundant_interfaces}
  end

  defp ensure_distinct_interfaces(_primary_interface, _secondary_interface), do: :ok

  defp parse_new_domain_id(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        {:error, :missing_domain_id}

      Regex.match?(~r/\A[a-zA-Z0-9_]+\z/, trimmed) ->
        {:ok, String.to_atom(trimmed)}

      true ->
        {:error, :invalid_domain_id}
    end
  end

  defp parse_new_domain_id(_value), do: {:error, :missing_domain_id}

  defp parse_positive_int(value, error_key) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int > 0 -> {:ok, int}
      _ -> {:error, error_key}
    end
  end

  defp parse_positive_int(value, _error_key) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp parse_positive_int(_value, error_key), do: {:error, error_key}

  defp build_captured_ethercat_config(attrs) do
    master_status = master_status()
    transport_fields = transport_form_fields_from_backend(Map.get(master_status, :backend))

    with {:ok, domains} <- capture_ethercat_domains(master_status),
         {:ok, slave_summaries} <- capture_slave_summaries(master_status),
         {:ok, slaves} <-
           capture_ethercat_slaves(
             slave_summaries,
             Enum.map(domains, &Keyword.fetch!(&1, :id))
           ) do
      now = System.system_time(:millisecond)
      config_id = Map.get(attrs, "id") || generated_capture_id(now)

      with {:ok, config_id} <- parse_config_id(config_id),
           {:ok, label} <- parse_label(Map.get(attrs, "label"), config_id) do
        form =
          normalized_simulation_form(
            Map.merge(transport_fields, %{
              "id" => config_id,
              "label" => label,
              "scan_stable_ms" => Integer.to_string(@default_scan_stable_ms),
              "scan_poll_ms" => Integer.to_string(@default_scan_poll_ms),
              "frame_timeout_ms" => Integer.to_string(@default_frame_timeout_ms)
            }),
            domains,
            slaves
          )

        {:ok,
         %HardwareConfig{
           id: config_id,
           protocol: :ethercat,
           label: label,
           inserted_at: existing_inserted_at(config_id, now),
           updated_at: now,
           spec:
             Map.merge(
               transport_spec_fields_from_form(transport_fields),
               %{
                 domains: domains,
                 scan_stable_ms: @default_scan_stable_ms,
                 scan_poll_ms: @default_scan_poll_ms,
                 frame_timeout_ms: @default_frame_timeout_ms,
                 slaves: slaves
               }
             ),
           meta: %{
             form: form,
             captured_from: %{source: :live_ethercat, captured_at: now}
           }
         }}
      end
    end
  end

  defp capture_ethercat_domains(%MasterStatus{} = status) do
    capture_ethercat_domains(configured_domains(status))
  end

  defp capture_ethercat_domains({:ok, domains}) when is_list(domains) do
    normalized =
      domains
      |> Enum.map(&normalize_capture_domain/1)
      |> Enum.reject(&is_nil/1)

    case normalized do
      [] ->
        {:ok,
         [
           [
             id: String.to_atom(@default_domain_id),
             cycle_time_us: @default_cycle_time_us,
             miss_threshold: 1000,
             recovery_threshold: 3
           ]
         ]}

      _ ->
        {:ok, normalized}
    end
  end

  defp capture_ethercat_domains(_other) do
    {:ok,
     [
       [
         id: String.to_atom(@default_domain_id),
         cycle_time_us: @default_cycle_time_us,
         miss_threshold: 1000,
         recovery_threshold: 3
       ]
     ]}
  end

  defp normalize_capture_domain([id: id, cycle_time_us: cycle_time_us] = domain)
       when is_atom(id) and is_integer(cycle_time_us) do
    [
      id: id,
      cycle_time_us: cycle_time_us,
      miss_threshold: Keyword.get(domain, :miss_threshold, 1000),
      recovery_threshold: Keyword.get(domain, :recovery_threshold, 3)
    ]
  end

  defp normalize_capture_domain({id, cycle_time_us, _stats})
       when is_atom(id) and is_integer(cycle_time_us) do
    [id: id, cycle_time_us: cycle_time_us, miss_threshold: 1000, recovery_threshold: 3]
  end

  defp normalize_capture_domain({id, %{cycle_time_us: cycle_time_us} = meta, _stats})
       when is_atom(id) and is_integer(cycle_time_us) do
    [
      id: id,
      cycle_time_us: cycle_time_us,
      miss_threshold: Map.get(meta, :miss_threshold, 1000),
      recovery_threshold: Map.get(meta, :recovery_threshold, 3)
    ]
  end

  defp normalize_capture_domain({id, _meta, _stats}) when is_atom(id) do
    [id: id, cycle_time_us: @default_cycle_time_us, miss_threshold: 1000, recovery_threshold: 3]
  end

  defp normalize_capture_domain(_other), do: nil

  defp capture_slave_summaries(%MasterStatus{} = status) do
    status
    |> configured_slave_summaries()
    |> then(fn
      [] -> {:error, :no_live_hardware}
      slave_summaries -> {:ok, slave_summaries}
    end)
  end

  defp capture_ethercat_slaves(slave_summaries, known_domain_ids) do
    slave_summaries
    |> Enum.reduce_while({:ok, []}, fn summary, {:ok, acc} ->
      with {:ok, info} <- Diagnostics.slave_info(summary.name) do
        {:cont, {:ok, acc ++ [captured_slave_config(summary.name, info, known_domain_ids)]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp captured_slave_config(slave_name, info, known_domain_ids) do
    signal_rows = Map.get(info, :signals, [])
    target_state = :op
    driver = Map.get(info, :driver) || EtherCAT.Driver.Default

    %SlaveConfig{
      name: slave_name,
      driver: driver,
      config: %{},
      process_data: captured_process_data(signal_rows, known_domain_ids, driver),
      target_state: target_state,
      health_poll_ms: default_health_poll_ms(target_state)
    }
  end

  defp captured_process_data([], known_domain_ids, driver),
    do: default_slave_process_data_spec(driver, known_domain_ids)

  defp captured_process_data(signal_rows, known_domain_ids, driver) do
    domains =
      signal_rows
      |> Enum.map(& &1.domain)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case domains do
      [domain_id] ->
        if domain_id in known_domain_ids do
          {:all, domain_id}
        else
          default_slave_process_data_spec(driver, known_domain_ids)
        end

      _other ->
        default_slave_process_data_spec(driver, known_domain_ids)
    end
  end

  defp parse_simulation_slaves(raw_rows, raw_lines, domains) do
    domain_ids = Enum.map(domains, &Keyword.fetch!(&1, :id))
    default_domain_id = List.first(domain_ids)

    case ordered_slave_rows(raw_rows) do
      [] ->
        parse_simulation_slave_lines(raw_lines, default_domain_id)

      rows ->
        rows
        |> Enum.reject(&blank_simulation_slave_row?/1)
        |> case do
          [] ->
            {:error, :missing_simulation_slaves}

          entries ->
            Enum.reduce_while(entries, {:ok, []}, fn row, {:ok, acc} ->
              with {:ok, slave_config} <-
                     parse_simulation_slave_row(row, default_domain_id, domain_ids) do
                {:cont, {:ok, acc ++ [slave_config]}}
              else
                {:error, _reason} = error -> {:halt, error}
              end
            end)
        end
    end
  end

  defp parse_simulation_slave_lines(raw, default_domain_id) when is_binary(raw) do
    entries =
      raw
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

    if entries == [] do
      {:error, :missing_simulation_slaves}
    else
      Enum.reduce_while(entries, {:ok, []}, fn line, {:ok, acc} ->
        with {:ok, slave_config} <- parse_simulation_slave_line(line, default_domain_id) do
          {:cont, {:ok, acc ++ [slave_config]}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp parse_simulation_slave_lines(_raw, _default_domain_id),
    do: {:error, :missing_simulation_slaves}

  defp parse_simulation_slave_line(line, default_domain_id) do
    case line
         |> String.split(",", trim: false)
         |> Enum.map(&String.trim/1) do
      [name, driver, target_state, process_data_mode, process_data_domain, health_poll_ms] ->
        with {:ok, slave_name} <- parse_new_domain_id(name),
             {:ok, driver_module} <- parse_driver(driver),
             {:ok, target_state_atom} <- parse_target_state(target_state),
             {:ok, process_data} <-
               parse_process_data_mode_string(
                 process_data_mode,
                 process_data_domain,
                 default_domain_id,
                 if(is_atom(default_domain_id), do: [default_domain_id], else: [])
               ),
             {:ok, health_poll} <- parse_health_poll_ms(health_poll_ms, target_state_atom) do
          {:ok,
           %SlaveConfig{
             name: slave_name,
             driver: driver_module,
             config: %{},
             process_data: process_data,
             target_state: target_state_atom,
             health_poll_ms: health_poll
           }}
        end

      _ ->
        {:error, {:invalid_slave_line, line}}
    end
  end

  defp parse_simulation_slave_row(row, default_domain_id, domain_ids) when is_map(row) do
    with {:ok, slave_name} <- parse_new_domain_id(Map.get(row, "name")),
         {:ok, driver_module} <- parse_driver(Map.get(row, "driver")),
         {:ok, target_state_atom} <-
           parse_target_state(Map.get(row, "target_state", "op")),
         {:ok, process_data} <-
           parse_process_data_mode_string(
             Map.get(row, "process_data_mode", "none"),
             Map.get(row, "process_data_domain", ""),
             default_domain_id,
             domain_ids
           ),
         {:ok, health_poll} <-
           parse_health_poll_ms(Map.get(row, "health_poll_ms", ""), target_state_atom) do
      {:ok,
       %SlaveConfig{
         name: slave_name,
         driver: driver_module,
         config: %{},
         process_data: process_data,
         target_state: target_state_atom,
         health_poll_ms: health_poll
       }}
    end
  end

  defp parse_process_data_mode_string(mode, domain, default_domain_id, domain_ids)
       when is_binary(mode) do
    case String.trim(mode) do
      "" ->
        {:ok, :none}

      "none" ->
        {:ok, :none}

      "all" ->
        with {:ok, domain_id} <- parse_line_domain_id(domain, default_domain_id, domain_ids) do
          {:ok, {:all, domain_id}}
        end

      other ->
        {:error, {:invalid_process_data_mode, other}}
    end
  end

  defp parse_line_domain_id(value, default_domain_id, domain_ids) when is_binary(value) do
    case String.trim(value) do
      "" ->
        if is_atom(default_domain_id),
          do: {:ok, default_domain_id},
          else: {:error, :missing_domain_id}

      trimmed ->
        case Enum.find(domain_ids, &(to_string(&1) == trimmed)) do
          nil -> {:error, {:unknown_domain, trimmed}}
          domain_id -> {:ok, domain_id}
        end
    end
  end

  defp parse_line_domain_id(_value, default_domain_id, domain_ids),
    do: parse_line_domain_id("", default_domain_id, domain_ids)

  defp default_slave_rows do
    {coupler_mode, coupler_domain} =
      default_slave_process_data(EtherCAT.Driver.EK1100, [@default_domain_id])

    {inputs_mode, inputs_domain} =
      default_slave_process_data(EtherCAT.Driver.EL1809, [@default_domain_id])

    {outputs_mode, outputs_domain} =
      default_slave_process_data(EtherCAT.Driver.EL2809, [@default_domain_id])

    [
      %{
        "name" => "coupler",
        "driver" => "EtherCAT.Driver.EK1100",
        "target_state" => "op",
        "process_data_mode" => coupler_mode,
        "process_data_domain" => coupler_domain,
        "health_poll_ms" => default_health_poll_field(:op)
      },
      %{
        "name" => "inputs",
        "driver" => "EtherCAT.Driver.EL1809",
        "target_state" => "op",
        "process_data_mode" => inputs_mode,
        "process_data_domain" => inputs_domain,
        "health_poll_ms" => default_health_poll_field(:op)
      },
      %{
        "name" => "outputs",
        "driver" => "EtherCAT.Driver.EL2809",
        "target_state" => "op",
        "process_data_mode" => outputs_mode,
        "process_data_domain" => outputs_domain,
        "health_poll_ms" => default_health_poll_field(:op)
      }
    ]
  end

  defp normalize_form_map(form) when is_map(form) do
    Enum.reduce(form, default_ethercat_simulation_form(), fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_form_map(_form), do: default_ethercat_simulation_form()

  defp default_domain_rows do
    [
      %{
        "id" => @default_domain_id,
        "cycle_time_us" => Integer.to_string(@default_cycle_time_us),
        "miss_threshold" => "1000",
        "recovery_threshold" => "3"
      }
    ]
  end

  defp existing_inserted_at(config_id, now) do
    case HardwareConfigStore.get_config(config_id) do
      %HardwareConfig{inserted_at: inserted_at} when is_integer(inserted_at) -> inserted_at
      _ -> now
    end
  end

  defp humanize_id(config_id) do
    config_id
    |> String.replace(["_", "-"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp generated_capture_id(now_ms) do
    "ethercat_capture_#{now_ms}"
  end

  defp signal_names(driver) do
    if function_exported?(driver, :signal_model, 2) do
      driver
      |> apply(:signal_model, [%{}, []])
      |> Keyword.keys()
    else
      []
    end
  rescue
    _error -> []
  end

  defp support_snapshot_id(kind, captured_at) do
    "hardware_#{kind}_snapshot_#{captured_at}"
  end

  defp sanitize_ethercat(ethercat) when is_map(ethercat) do
    Map.take(ethercat, [
      :protocol,
      :label,
      :master_status,
      :simulator_status,
      :state,
      :configurable?,
      :activatable?,
      :deactivatable?,
      :bus,
      :dc_status,
      :reference_clock,
      :last_failure,
      :domains,
      :aggregate_snapshot,
      :slaves,
      :hardware_snapshots
    ])
  end

  defp context_mode(%{mode: mode}, key) when is_map(mode), do: Map.get(mode, key)
  defp context_mode(_, _key), do: nil

  defp context_observed(%{observed: observed}, key) when is_map(observed),
    do: Map.get(observed, key)

  defp context_observed(_, _key), do: nil

  defp context_summary(%{summary: summary}, key) when is_map(summary), do: Map.get(summary, key)
  defp context_summary(_, _key), do: nil

  defp config_form_defaults(slave_name, info, domain_ids) do
    signal_rows = Map.get(info, :signals, [])
    domain_hint = signal_rows |> Enum.map(& &1.domain) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    target_state = infer_target_state(Map.get(info, :al_state))

    %{
      "slave" => to_string(slave_name),
      "driver" => format_module(Map.get(info, :driver) || EtherCAT.Driver.Default),
      "process_data_mode" => infer_process_data_mode(signal_rows),
      "process_data_domain" => infer_process_data_domain(domain_hint, domain_ids),
      "process_data_signals" => signal_rows_to_text(signal_rows),
      "target_state" => target_state,
      "health_poll_ms" => default_health_poll_field(target_state)
    }
  end

  defp infer_process_data_mode([]), do: "none"
  defp infer_process_data_mode(_signals), do: "signals"

  defp infer_process_data_domain([domain_id], _known_domain_ids), do: to_string(domain_id)

  defp infer_process_data_domain(_domains, known_domain_ids) do
    case known_domain_ids do
      [domain_id | _rest] -> to_string(domain_id)
      [] -> ""
    end
  end

  defp infer_target_state(:preop), do: "preop"
  defp infer_target_state(_al_state), do: "op"

  defp default_health_poll_ms(_target_state), do: @default_health_poll_ms

  defp default_health_poll_field(target_state) do
    target_state
    |> default_health_poll_ms()
    |> Integer.to_string()
  end

  defp health_poll_field(nil, _target_state), do: "disabled"

  defp health_poll_field(health_poll_ms, _target_state) when is_integer(health_poll_ms) do
    Integer.to_string(health_poll_ms)
  end

  defp health_poll_field(_value, target_state), do: default_health_poll_field(target_state)

  defp process_data_mode_value(:none), do: "none"
  defp process_data_mode_value({:all, _domain}), do: "all"
  defp process_data_mode_value(_other), do: "none"

  defp default_slave_process_data(driver, domain_ids) do
    default_domain = List.first(domain_ids) |> Kernel.||(@default_domain_id) |> to_string()
    driver = driver_module_for_defaults(driver)

    case signal_names(driver) do
      [] -> {"none", default_domain}
      _signals -> {"all", default_domain}
    end
  end

  defp default_slave_process_data_spec(driver, domain_ids) do
    driver = driver_module_for_defaults(driver)

    case {signal_names(driver), List.first(domain_ids)} do
      {[], _domain} -> :none
      {_signals, domain_id} when is_atom(domain_id) -> {:all, domain_id}
      _other -> :none
    end
  end

  defp driver_module_for_defaults(driver) when is_atom(driver), do: driver

  defp driver_module_for_defaults(driver) when is_binary(driver) do
    driver
    |> String.trim()
    |> String.trim_leading("Elixir.")
    |> then(&Module.concat([&1]))
  end

  defp driver_module_for_defaults(_driver), do: EtherCAT.Driver.Default

  defp simulation_driver?(module) when is_atom(module) do
    module_name = Atom.to_string(module)

    String.starts_with?(module_name, "Elixir.EtherCAT.Driver.") and
      not String.ends_with?(module_name, ".Simulator") and
      Code.ensure_loaded?(Module.concat(module, "Simulator"))
  end

  defp simulation_driver?(_module), do: false

  defp signal_rows_to_text(signal_rows) do
    signal_rows
    |> Enum.map(fn row -> "#{row.name}@#{row.domain}" end)
    |> Enum.join("\n")
  end

  defp domain_ids({:ok, domains}) when is_list(domains) do
    Enum.map(domains, fn
      {id, _cycle_time_us, _pid} when is_atom(id) -> id
      {id, _cycle_time_us, _stats} when is_atom(id) -> id
      %{"id" => id} when is_binary(id) -> String.to_atom(id)
      %{id: id} when is_atom(id) -> id
      [id: id] when is_atom(id) -> id
    end)
  end

  defp domain_ids(_), do: []

  defp summarize_spec(%SlaveConfig{} = spec) do
    %{
      driver: format_module(spec.driver),
      process_data: inspect(spec.process_data),
      target_state: spec.target_state,
      health_poll_ms: spec.health_poll_ms
    }
  end

  defp format_module(module) when is_atom(module) do
    module
    |> inspect()
    |> String.replace_prefix("Elixir.", "")
  end

  defp ordered_slave_rows(nil), do: []

  defp ordered_slave_rows(rows) when is_list(rows) do
    Enum.map(rows, &normalize_slave_row_keys/1)
  end

  defp ordered_slave_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} ->
      case Integer.parse(to_string(index)) do
        {int, ""} -> int
        _ -> 999_999
      end
    end)
    |> Enum.map(fn {_index, row} -> normalize_slave_row_keys(row) end)
  end

  defp ordered_slave_rows(_rows), do: []

  defp normalize_slave_row_keys(row) when is_map(row) do
    Enum.reduce(row, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp normalize_simulation_domain_rows(nil), do: default_domain_rows()

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

  defp normalize_simulation_domain_rows(_rows), do: default_domain_rows()

  defp normalize_simulation_domain_row(row) when is_map(row) do
    row
    |> Enum.reduce(%{}, fn {key, value}, acc -> Map.put(acc, to_string(key), value) end)
    |> Map.put_new("id", @default_domain_id)
    |> Map.put_new("cycle_time_us", Integer.to_string(@default_cycle_time_us))
    |> Map.put_new("miss_threshold", "1000")
    |> Map.put_new("recovery_threshold", "3")
  end

  defp normalize_simulation_domain_row(_row), do: hd(default_domain_rows())

  defp normalize_simulation_slave_rows(rows, _domain_ids) when is_list(rows) do
    Enum.map(rows, &normalize_simulation_slave_row/1)
  end

  defp normalize_simulation_slave_rows(rows, _domain_ids) when is_map(rows) do
    rows
    |> ordered_slave_rows()
    |> Enum.map(&normalize_simulation_slave_row/1)
  end

  defp normalize_simulation_slave_rows(_rows, _domain_ids), do: default_slave_rows()

  defp normalize_simulation_slave_row(row) when is_map(row) do
    row = normalize_slave_row_keys(row)

    {process_data_mode, process_data_domain} =
      default_slave_process_data(Map.get(row, "driver"), [@default_domain_id])

    row
    |> Map.put_new("target_state", "op")
    |> Map.put_new("process_data_mode", process_data_mode)
    |> Map.put_new("process_data_domain", process_data_domain)
    |> Map.put_new("health_poll_ms", default_health_poll_field(:op))
  end

  defp normalize_simulation_slave_row(_row), do: hd(default_slave_rows())

  defp blank_simulation_slave_row?(row) do
    Enum.all?(
      ["name", "driver"],
      fn key -> row |> Map.get(key, "") |> to_string() |> String.trim() == "" end
    )
  end

  defp apply_simulation_defaults(params) do
    params
    |> Map.put_new("transport", "udp")
    |> Map.put_new("bind_ip", @default_bind_ip)
    |> Map.put_new("simulator_ip", @default_simulator_ip)
    |> Map.put_new("primary_interface", "")
    |> Map.put_new("secondary_interface", "")
    |> Map.put_new("domains", default_domain_rows())
    |> Map.put_new("scan_stable_ms", Integer.to_string(@default_scan_stable_ms))
    |> Map.put_new("scan_poll_ms", Integer.to_string(@default_scan_poll_ms))
    |> Map.put_new("frame_timeout_ms", Integer.to_string(@default_frame_timeout_ms))
  end

  defp stringify_map_keys(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp normalized_simulation_form(params, domains, slaves) do
    params
    |> Map.take(Map.keys(default_ethercat_simulation_form()) -- ["domains", "slaves"])
    |> Map.put("domains", Enum.map(domains, &simulation_domain_form_row/1))
    |> Map.put("slaves", Enum.map(slaves, &simulation_slave_form_row/1))
  end

  defp simulation_domain_form_row(domain) when is_list(domain) do
    %{
      "id" => domain |> Keyword.fetch!(:id) |> to_string(),
      "cycle_time_us" => domain |> Keyword.fetch!(:cycle_time_us) |> Integer.to_string(),
      "miss_threshold" => domain |> Keyword.get(:miss_threshold, 1000) |> Integer.to_string(),
      "recovery_threshold" => domain |> Keyword.get(:recovery_threshold, 3) |> Integer.to_string()
    }
  end

  defp simulation_slave_form_row(%SlaveConfig{} = slave) do
    {mode, domain} =
      case slave.process_data do
        :none -> {"none", ""}
        {:all, domain_id} -> {"all", to_string(domain_id)}
        _other -> {"none", ""}
      end

    %{
      "name" => to_string(slave.name),
      "driver" => format_module(slave.driver),
      "target_state" => to_string(slave.target_state || :op),
      "process_data_mode" => mode,
      "process_data_domain" => domain,
      "health_poll_ms" =>
        if(is_integer(slave.health_poll_ms),
          do: Integer.to_string(slave.health_poll_ms),
          else: ""
        )
    }
  end

  defp transport_form_fields_from_backend(%Backend.Udp{} = backend) do
    %{
      "transport" => "udp",
      "bind_ip" => format_ip(backend.bind_ip || @default_bind_ip),
      "simulator_ip" => format_ip(backend.host),
      "primary_interface" => "",
      "secondary_interface" => ""
    }
  end

  defp transport_form_fields_from_backend(%Backend.Raw{} = backend) do
    %{
      "transport" => "raw",
      "bind_ip" => @default_bind_ip,
      "simulator_ip" => @default_simulator_ip,
      "primary_interface" => backend.interface,
      "secondary_interface" => ""
    }
  end

  defp transport_form_fields_from_backend(%Backend.Redundant{} = backend) do
    %{
      "transport" => "redundant",
      "bind_ip" => @default_bind_ip,
      "simulator_ip" => @default_simulator_ip,
      "primary_interface" => backend.primary.interface,
      "secondary_interface" => backend.secondary.interface
    }
  end

  defp transport_form_fields_from_backend(_backend) do
    %{
      "transport" => "udp",
      "bind_ip" => @default_bind_ip,
      "simulator_ip" => @default_simulator_ip,
      "primary_interface" => "",
      "secondary_interface" => ""
    }
  end

  defp transport_spec_fields_from_form(form) do
    case Map.get(form, "transport") do
      "raw" ->
        %{
          transport: :raw,
          bind_ip: nil,
          simulator_ip: nil,
          primary_interface: Map.get(form, "primary_interface") |> blank_to_nil(),
          secondary_interface: nil
        }

      "redundant" ->
        %{
          transport: :redundant,
          bind_ip: nil,
          simulator_ip: nil,
          primary_interface: Map.get(form, "primary_interface") |> blank_to_nil(),
          secondary_interface: Map.get(form, "secondary_interface") |> blank_to_nil()
        }

      _other ->
        %{
          transport: :udp,
          bind_ip: parse_ip_field(Map.get(form, "bind_ip"), @default_bind_ip),
          simulator_ip: parse_ip_field(Map.get(form, "simulator_ip"), @default_simulator_ip),
          primary_interface: nil,
          secondary_interface: nil
        }
    end
  end

  defp discover_raw_interfaces do
    case File.ls("/sys/class/net") do
      {:ok, interfaces} ->
        interfaces
        |> normalize_configured_interfaces()
        |> Enum.filter(&raw_interface_available?/1)

      {:error, _reason} ->
        []
    end
  end

  defp normalize_configured_interfaces(interfaces) do
    interfaces
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or &1 == "lo"))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp raw_interface_available?(interface) do
    File.exists?("/sys/class/net/#{interface}") and
      match?({:ok, _ifindex}, :net.if_name2index(String.to_charlist(interface)))
  end

  defp parse_ip_field(value, default) do
    case parse_ip(value, :ip) do
      {:ok, ip} -> ip
      {:error, _reason} -> default
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp format_ip({_, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip({_, _, _, _, _, _, _, _} = ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip) when is_binary(ip), do: ip
  defp format_ip(_other), do: @default_bind_ip

  defp parse_simulation_domains(raw_rows, legacy_id, legacy_cycle_time_us) do
    case ordered_domain_rows(raw_rows) do
      [] ->
        parse_legacy_simulation_domains(legacy_id, legacy_cycle_time_us)

      rows ->
        rows
        |> Enum.reject(&blank_simulation_domain_row?/1)
        |> case do
          [] ->
            {:error, :missing_domain_id}

          entries ->
            entries
            |> Enum.with_index()
            |> Enum.reduce_while({:ok, []}, fn {row, idx}, {:ok, acc} ->
              case parse_simulation_domain_row(row) do
                {:ok, domain} -> {:cont, {:ok, acc ++ [domain]}}
                {:error, reason} -> {:halt, {:error, {:invalid_domain_config, idx, reason}}}
              end
            end)
            |> case do
              {:ok, domains} ->
                case ensure_unique_domain_ids(domains) do
                  :ok -> {:ok, domains}
                  {:error, _} = error -> error
                end

              {:error, _} = error ->
                error
            end
        end
    end
  end

  defp parse_legacy_simulation_domains(legacy_id, legacy_cycle_time_us) do
    with {:ok, domain_id} <- parse_new_domain_id(legacy_id),
         {:ok, cycle_time_us} <- parse_positive_int(legacy_cycle_time_us, :domain_cycle_us) do
      {:ok,
       [
         [
           id: domain_id,
           cycle_time_us: cycle_time_us,
           miss_threshold: 1000,
           recovery_threshold: 3
         ]
       ]}
    end
  end

  defp parse_simulation_domain_row(row) do
    with {:ok, id} <- parse_new_domain_id(Map.get(row, "id")),
         {:ok, cycle_time_us} <-
           parse_positive_int(Map.get(row, "cycle_time_us"), :domain_cycle_us),
         {:ok, miss_threshold} <-
           parse_positive_int(Map.get(row, "miss_threshold"), :miss_threshold),
         {:ok, recovery_threshold} <-
           parse_positive_int(Map.get(row, "recovery_threshold"), :recovery_threshold) do
      {:ok,
       [
         id: id,
         cycle_time_us: cycle_time_us,
         miss_threshold: miss_threshold,
         recovery_threshold: recovery_threshold
       ]}
    end
  end

  defp ordered_domain_rows(nil), do: []

  defp ordered_domain_rows(rows) when is_list(rows) do
    Enum.map(rows, &normalize_domain_row_keys/1)
  end

  defp ordered_domain_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {index, _row} ->
      case Integer.parse(to_string(index)) do
        {int, ""} -> int
        _ -> 999_999
      end
    end)
    |> Enum.map(fn {_index, row} -> normalize_domain_row_keys(row) end)
  end

  defp ordered_domain_rows(_rows), do: []

  defp normalize_domain_row_keys(row) when is_map(row) do
    Enum.reduce(row, %{}, fn {key, value}, acc ->
      Map.put(acc, to_string(key), value)
    end)
  end

  defp blank_simulation_domain_row?(row) do
    Enum.all?(["id", "cycle_time_us", "miss_threshold", "recovery_threshold"], fn key ->
      row |> Map.get(key, "") |> to_string() |> String.trim() == ""
    end)
  end

  defp ensure_unique_domain_ids(domains) do
    domains
    |> Enum.with_index()
    |> Enum.reduce_while(%{}, fn {domain, idx}, seen ->
      id = Keyword.fetch!(domain, :id)

      if Map.has_key?(seen, id) do
        {:halt, {:error, {:duplicate_domain_id, idx, id}}}
      else
        {:cont, Map.put(seen, id, idx)}
      end
    end)
    |> case do
      %{} -> :ok
      {:error, _} = error -> error
    end
  end
end
