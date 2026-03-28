defmodule Ogol.HMI.HardwareContext do
  @moduledoc false

  alias Ogol.HMI.HardwareConfig
  alias Ogol.HMI.Notification

  defstruct observed: %{},
            mode: %{},
            pre_arm: %{},
            summary: %{},
            commissioning: nil,
            section_order: []

  @type t :: %__MODULE__{
          observed: map(),
          mode: map(),
          pre_arm: map(),
          summary: map(),
          commissioning: map() | nil,
          section_order: [atom()]
        }

  @spec build(map(), [Notification.t()], [HardwareConfig.t()], keyword()) :: t()
  def build(ethercat, events, saved_configs, opts \\ [])
      when is_map(ethercat) and is_list(events) and is_list(saved_configs) do
    now_ms = Keyword.get(opts, :now_ms, System.system_time(:millisecond))
    simulator? = simulator_running?(ethercat)
    active_config = active_config(events, saved_configs)

    observed =
      build_observed(
        ethercat,
        events,
        active_config,
        simulator?,
        now_ms,
        Keyword.get(opts, :host_kind, :controller)
      )

    mode =
      build_mode(
        observed,
        Keyword.get(opts, :mode),
        Keyword.get(opts, :permission, :engineer),
        Keyword.get(opts, :deployment_policy, :default)
      )

    pre_arm = build_pre_arm(observed)
    summary = build_summary(observed, mode)
    commissioning = build_commissioning(ethercat, active_config)

    %__MODULE__{
      observed: observed,
      mode: mode,
      pre_arm: pre_arm,
      summary: summary,
      commissioning: commissioning,
      section_order: section_order(mode[:kind], commissioning, observed)
    }
  end

  defp build_observed(ethercat, events, active_config, simulator?, now_ms, host_kind) do
    source = source_kind(ethercat, simulator?, active_config, now_ms)
    backend_kind = backend_kind(source)
    truth_source = truth_source(source, host_kind)
    coupling = coupling(ethercat)
    last_update_at = last_update_at(ethercat, events, source, simulator?, now_ms)
    staleness_ms = staleness_ms(last_update_at, now_ms)
    freshness = freshness(source, staleness_ms)
    expectation = hardware_expectation(source, ethercat)
    commissioning = build_commissioning(ethercat, active_config)
    topology_match = topology_match(expectation, source, commissioning)
    runtime_health = runtime_health(ethercat, source, freshness, topology_match, coupling)
    fault_scope = fault_scope(ethercat, freshness, coupling, runtime_health)

    %{
      host_kind: host_kind,
      source: source,
      backend_kind: backend_kind,
      truth_source: truth_source,
      coupling: coupling,
      hardware_expectation: expectation,
      topology_match: topology_match,
      last_update_at: maybe_datetime(last_update_at),
      staleness_ms: staleness_ms,
      freshness: freshness,
      runtime_health: runtime_health,
      fault_scope: fault_scope
    }
  end

  defp build_mode(observed, mode_override, permission, deployment_policy) do
    kind = normalize_mode(mode_override || default_mode(observed), observed)
    write_policy = write_policy(observed, kind, permission, deployment_policy)

    %{
      kind: kind,
      armable?: observed.source == :live,
      write_policy: write_policy,
      authority_scope: authority_scope(observed, kind, write_policy)
    }
  end

  defp build_pre_arm(observed) do
    issues =
      []
      |> maybe_add(observed.source != :live, "live hardware is not connected")
      |> maybe_add(observed.freshness != :live, "hardware freshness is not live")
      |> maybe_add(
        observed.runtime_health in [:disconnected, :unknown],
        "runtime health is not ready"
      )

    warnings =
      []
      |> maybe_add(
        observed.topology_match in [:missing, :extra, :swapped, :multiple],
        "topology match is #{labelize(observed.topology_match)}"
      )
      |> maybe_add(observed.runtime_health == :degraded, "runtime health is degraded")

    {status, label, detail} =
      cond do
        issues != [] ->
          {:blocked, "Blocked", Enum.join(issues, "; ")}

        warnings != [] ->
          {:caution, "Caution", Enum.join(warnings, "; ")}

        true ->
          {:ready, "Ready", "live hardware is present and freshness is current"}
      end

    %{status: status, label: label, detail: detail, issues: issues, warnings: warnings}
  end

  defp build_summary(observed, mode) do
    state =
      cond do
        observed.source == :simulator ->
          :simulated

        observed.hardware_expectation == :none and observed.source == :none ->
          :expected_none

        observed.truth_source == :remote_runtime and observed.freshness == :stale ->
          :remote_stale

        observed.runtime_health == :healthy and observed.source == :live ->
          :live_healthy

        observed.runtime_health in [:degraded, :unknown] and observed.source == :live ->
          :live_degraded

        observed.runtime_health == :disconnected or
            (observed.hardware_expectation == :required and observed.source == :none) ->
          :disconnected_fault

        true ->
          :live_degraded
      end

    %{state: state, label: summary_label(state), detail: summary_detail(state, observed, mode)}
  end

  defp build_commissioning(ethercat, %HardwareConfig{} = active_config) do
    actual =
      ethercat
      |> Map.get(:slaves, [])
      |> Enum.map(fn slave ->
        %{
          name: to_string(slave.name),
          al_state: slave_al_state(slave),
          driver: slave_driver(slave)
        }
      end)

    expected =
      active_config.spec
      |> Map.get(:slaves, [])
      |> Enum.map(fn slave ->
        %{
          name: to_string(slave.name),
          target_state: slave.target_state,
          driver: inspect(slave.driver)
        }
      end)

    actual_by_name = Map.new(actual, &{&1.name, &1})
    expected_names = Enum.map(expected, & &1.name)
    actual_names = Enum.map(actual, & &1.name)

    identity_mismatches =
      Enum.flat_map(expected, fn expected_slave ->
        case Map.get(actual_by_name, expected_slave.name) do
          nil ->
            []

          actual_slave ->
            if normalize_driver(actual_slave.driver) == normalize_driver(expected_slave.driver) do
              []
            else
              [
                %{
                  name: expected_slave.name,
                  expected: expected_slave.driver,
                  actual: actual_slave.driver
                }
              ]
            end
        end
      end)

    state_mismatches =
      Enum.flat_map(expected, fn expected_slave ->
        case Map.get(actual_by_name, expected_slave.name) do
          nil ->
            []

          actual_slave ->
            if to_string(expected_slave.target_state) == actual_slave.al_state do
              []
            else
              [
                %{
                  name: expected_slave.name,
                  expected: expected_slave.target_state,
                  actual: actual_slave.al_state
                }
              ]
            end
        end
      end)

    %{
      config_id: active_config.id,
      expected_devices: expected_names,
      actual_devices: actual_names,
      missing_devices:
        expected_names
        |> Enum.reject(&Map.has_key?(actual_by_name, &1)),
      extra_devices:
        actual_names
        |> Enum.reject(fn name -> name in expected_names end),
      identity_mismatches: identity_mismatches,
      state_mismatches: state_mismatches,
      mapping_mismatches: [],
      inhibited_outputs:
        expected
        |> Enum.filter(&(to_string(&1.target_state) != "op"))
        |> Enum.map(& &1.name)
    }
  end

  defp build_commissioning(_ethercat, _active_config), do: nil

  defp section_order(:testing, _commissioning?, %{source: :none}), do: [:simulation, :master]

  defp section_order(:testing, commissioning?, %{source: :simulator}) do
    case commissioning? do
      nil -> [:simulation, :master, :status, :devices, :diagnostics]
      _ -> [:simulation, :master, :commissioning, :status, :devices, :diagnostics]
    end
  end

  defp section_order(:testing, commissioning?, %{source: :live}) do
    [:master, :status, :capture, :devices, :diagnostics]
    |> maybe_commissioning(commissioning?)
  end

  defp section_order(:armed, commissioning?, %{source: :live}) do
    [:master, :status, :capture, :devices, :diagnostics, :provisioning]
    |> maybe_commissioning(commissioning?)
  end

  defp section_order(_kind, commissioning?, observed) do
    section_order(:testing, commissioning?, %{observed | source: :none})
  end

  defp maybe_commissioning(sections, nil), do: sections
  defp maybe_commissioning([first | rest], _), do: [first, :commissioning | rest]

  defp simulator_running?(%{simulator_status: %{lifecycle: :running}}), do: true
  defp simulator_running?(_ethercat), do: false

  defp source_kind(_ethercat, true, _active_config, _now_ms), do: :simulator

  defp source_kind(_ethercat, false, %HardwareConfig{}, _now_ms), do: :simulator

  defp source_kind(ethercat, false, _active_config, now_ms) do
    cond do
      active_runtime?(ethercat) -> :live
      recent_hardware_snapshot?(ethercat, now_ms) -> :live
      true -> :none
    end
  end

  defp backend_kind(:live), do: :real
  defp backend_kind(:simulator), do: :simulated
  defp backend_kind(:none), do: :none

  defp truth_source(:simulator, _host_kind), do: :simulator
  defp truth_source(_source, :remote), do: :remote_runtime
  defp truth_source(:none, _host_kind), do: :snapshot
  defp truth_source(_source, _host_kind), do: :local_runtime

  defp coupling(ethercat) do
    snapshot_count = hardware_snapshot_count(ethercat)
    slave_count = slave_count(ethercat)

    cond do
      snapshot_count == 0 -> :detached
      slave_count == 0 -> :attached
      snapshot_count < slave_count -> :partial
      true -> :attached
    end
  end

  defp last_update_at(ethercat, events, source, simulator?, now_ms) do
    snapshot_ts =
      ethercat
      |> Map.get(:hardware_snapshots, [])
      |> Enum.map(& &1.last_feedback_at)
      |> Enum.reject(&is_nil/1)

    event_ts =
      events
      |> Enum.filter(&hardware_event?(&1))
      |> Enum.map(& &1.occurred_at)

    active_ts =
      if (source == :simulator and simulator?) or
           (source != :none and active_runtime?(ethercat)) do
        [now_ms]
      else
        []
      end

    case snapshot_ts ++ event_ts ++ active_ts do
      [] -> nil
      timestamps -> Enum.max(timestamps)
    end
  end

  defp staleness_ms(nil, _now_ms), do: nil
  defp staleness_ms(last_update_at, now_ms), do: max(now_ms - last_update_at, 0)

  defp freshness(:none, nil), do: :unknown
  defp freshness(:none, _staleness_ms), do: :stale
  defp freshness(_source, nil), do: :unknown
  defp freshness(_source, staleness_ms) when staleness_ms <= 2_000, do: :live
  defp freshness(_source, _staleness_ms), do: :stale

  defp hardware_expectation(:simulator, _ethercat), do: :none

  defp hardware_expectation(:none, _ethercat), do: :none

  defp hardware_expectation(:live, ethercat) do
    case session_state_name(ethercat) do
      :operational -> :required
      :preop_ready -> :required
      :activation_blocked -> :required
      :recovering -> :required
      _other -> :optional
    end
  end

  defp topology_match(:none, :none, _commissioning), do: :match
  defp topology_match(:none, :simulator, _commissioning), do: :match
  defp topology_match(:required, :none, _commissioning), do: :missing
  defp topology_match(_expectation, _source, nil), do: :unknown

  defp topology_match(_expectation, _source, commissioning) do
    mismatch_classes =
      []
      |> maybe_add(commissioning.missing_devices != [], :missing)
      |> maybe_add(commissioning.extra_devices != [], :extra)
      |> maybe_add(commissioning.identity_mismatches != [], :swapped)

    case mismatch_classes do
      [] -> :match
      [single] -> single
      _many -> :multiple
    end
  end

  defp runtime_health(ethercat, _source, :unknown, _topology_match, _coupling) do
    if active_runtime?(ethercat), do: :healthy, else: :unknown
  end

  defp runtime_health(_ethercat, :none, _freshness, _topology_match, _coupling), do: :disconnected

  defp runtime_health(ethercat, _source, _freshness, topology_match, coupling) do
    cond do
      match?({:error, _}, Map.get(ethercat, :state)) ->
        :disconnected

      session_state_name(ethercat) in [:activation_blocked, :recovering] ->
        :degraded

      not nil_or_empty?(failure_value(ethercat)) ->
        :degraded

      any_slave_fault?(ethercat) ->
        :degraded

      topology_match in [:missing, :extra, :swapped, :multiple] ->
        :degraded

      coupling == :partial ->
        :degraded

      true ->
        :healthy
    end
  end

  defp fault_scope(_ethercat, :unknown, _coupling, :unknown), do: :unknown

  defp fault_scope(ethercat, freshness, coupling, _runtime_health) do
    scopes =
      []
      |> maybe_add(not nil_or_empty?(failure_value(ethercat)), :fieldbus_segment)
      |> maybe_add(any_slave_fault?(ethercat), :local_device)
      |> maybe_add(coupling == :partial, :runtime_coupling)
      |> maybe_add(freshness == :stale and not active_runtime?(ethercat), :remote_link)

    case scopes do
      [] -> :none
      [single] -> single
      _many -> :multiple
    end
  end

  defp default_mode(%{source: :live}), do: :armed
  defp default_mode(_observed), do: :testing

  defp normalize_mode(:armed, %{source: :live}), do: :armed
  defp normalize_mode(:armed, _observed), do: :testing
  defp normalize_mode(:testing, _observed), do: :testing
  defp normalize_mode(_other, observed), do: default_mode(observed)

  defp write_policy(_observed, _kind, :viewer, _deployment_policy), do: :blocked
  defp write_policy(%{truth_source: :remote_runtime}, _kind, _permission, _policy), do: :blocked
  defp write_policy(%{source: :none}, :testing, _permission, _policy), do: :enabled
  defp write_policy(%{source: :simulator}, :testing, _permission, _policy), do: :enabled
  defp write_policy(%{source: :live}, :testing, _permission, _policy), do: :restricted
  defp write_policy(%{source: :live}, :armed, _permission, _policy), do: :confirmed
  defp write_policy(_observed, _kind, _permission, _policy), do: :blocked

  defp authority_scope(_observed, _kind, :blocked), do: :observe_only

  defp authority_scope(%{source: source}, :testing, :enabled)
       when source in [:none, :simulator],
       do: :draft_and_simulation

  defp authority_scope(%{source: :live}, :testing, :restricted), do: :capture_and_compare
  defp authority_scope(%{source: :live}, :armed, :confirmed), do: :live_runtime_changes
  defp authority_scope(_observed, _kind, :enabled), do: :draft_local
  defp authority_scope(_observed, _kind, :restricted), do: :capture_and_compare

  defp summary_label(:live_healthy), do: "Live Healthy"
  defp summary_label(:live_degraded), do: "Live Degraded"
  defp summary_label(:simulated), do: "Simulated"
  defp summary_label(:expected_none), do: "Expected No Hardware"
  defp summary_label(:disconnected_fault), do: "Disconnected Fault"
  defp summary_label(:remote_stale), do: "Remote Stale"

  defp summary_detail(:live_healthy, observed, mode) do
    suffix =
      case mode.kind do
        :armed -> "Armed mode allows confirmed live actions."
        :testing -> "Testing mode keeps live edits blocked and favors capture + comparison."
      end

    "Live hardware is online with #{labelize(observed.coupling)} coupling. #{suffix}"
  end

  defp summary_detail(:live_degraded, observed, _mode) do
    "Hardware truth is degraded. Scope=#{labelize(observed.fault_scope)} freshness=#{labelize(observed.freshness)}."
  end

  defp summary_detail(:simulated, _observed, _mode) do
    "Runtime is backed by the simulator. Treat signals and state as simulated truth."
  end

  defp summary_detail(:expected_none, _observed, mode) do
    case mode.kind do
      :testing ->
        "No live hardware is active. Testing stays focused on saved configs and simulator setup."

      :armed ->
        "No live hardware is active, so armed mode is unavailable."
    end
  end

  defp summary_detail(:disconnected_fault, observed, _mode) do
    "Required hardware is missing or disconnected. Match=#{labelize(observed.topology_match)}."
  end

  defp summary_detail(:remote_stale, _observed, _mode) do
    "Remote truth is stale. Prefer reduced authority until freshness recovers."
  end

  defp maybe_datetime(nil), do: nil
  defp maybe_datetime(value), do: DateTime.from_unix!(value, :millisecond)

  defp active_runtime?(ethercat) do
    case session_state_name(ethercat) do
      nil -> false
      :idle -> false
      _state -> true
    end
  end

  defp hardware_snapshot_count(ethercat) do
    ethercat |> Map.get(:hardware_snapshots, []) |> length()
  end

  defp recent_hardware_snapshot?(ethercat, now_ms) do
    ethercat
    |> Map.get(:hardware_snapshots, [])
    |> Enum.map(& &1.last_feedback_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn feedback_at -> now_ms - feedback_at <= 2_000 end)
  end

  defp slave_count(ethercat) do
    ethercat |> Map.get(:slaves, []) |> length()
  end

  defp session_state_name(ethercat) do
    case Map.get(ethercat, :master_status) do
      %{lifecycle: :stopped} ->
        nil

      %{lifecycle: state} when is_atom(state) ->
        state

      _other ->
        case Map.get(ethercat, :state) do
          {:ok, state} when is_atom(state) -> state
          state when is_atom(state) -> state
          _other -> nil
        end
    end
  end

  defp failure_value(ethercat) do
    case Map.get(ethercat, :master_status) do
      %{last_failure: value} ->
        value

      _other ->
        case Map.get(ethercat, :last_failure) do
          {:ok, value} -> value
          {:error, _reason} -> :error
          value -> value
        end
    end
  end

  defp any_slave_fault?(ethercat) do
    has_status_faults? =
      case Map.get(ethercat, :master_status) do
        %{slave_faults: slave_faults} when map_size(slave_faults) > 0 -> true
        %{runtime_faults: runtime_faults} when map_size(runtime_faults) > 0 -> true
        _other -> false
      end

    has_status_faults? or
      Enum.any?(Map.get(ethercat, :slaves, []), fn slave ->
        not is_nil(slave.fault) or
          match?({:ok, %{faults: faults}} when faults not in [[], nil], slave.snapshot)
      end)
  end

  defp slave_al_state(slave) do
    case slave.info do
      {:ok, info} -> to_string(info[:al_state] || "unknown")
      _other -> "unknown"
    end
  end

  defp slave_driver(slave) do
    case slave.info do
      {:ok, info} -> inspect(info[:driver] || "unknown")
      _other -> "unknown"
    end
  end

  defp normalize_driver(driver), do: driver |> to_string() |> String.replace_prefix("Elixir.", "")

  defp active_config(events, saved_configs) do
    case latest_simulation_lifecycle(events) do
      {:started, config_id} ->
        Enum.find(saved_configs, &(&1.id == config_id)) ||
          latest_simulation_config(events, config_id)

      _other ->
        nil
    end
  end

  defp latest_simulation_config(events, config_id) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Notification{
        type: :hardware_simulation_started,
        payload: %{config_id: ^config_id, config: %HardwareConfig{} = config}
      } ->
        config

      _other ->
        nil
    end)
  end

  defp hardware_event?(%Notification{} = event) do
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
  end

  defp latest_simulation_lifecycle(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      case {event.type, simulation_config_id(event)} do
        {:hardware_simulation_started, config_id} when is_binary(config_id) ->
          {:started, config_id}

        {:hardware_simulation_failed, config_id} when is_binary(config_id) ->
          {:failed, config_id}

        {:hardware_simulation_stopped, config_id} when is_binary(config_id) ->
          {:stopped, config_id}

        {:hardware_simulation_stopped, nil} ->
          {:stopped, nil}

        _other ->
          nil
      end
    end)
  end

  defp simulation_config_id(%Notification{meta: %{config_id: config_id}})
       when is_binary(config_id),
       do: config_id

  defp simulation_config_id(%Notification{payload: %{config_id: config_id}})
       when is_binary(config_id),
       do: config_id

  defp simulation_config_id(_event), do: nil

  defp nil_or_empty?(nil), do: true
  defp nil_or_empty?([]), do: true
  defp nil_or_empty?(%{} = map), do: map == %{}
  defp nil_or_empty?(_value), do: false

  defp maybe_add(items, false, _item), do: items
  defp maybe_add(items, true, item), do: [item | items]

  defp labelize(value) when is_atom(value) do
    value |> Atom.to_string() |> String.replace("_", " ")
  end
end
