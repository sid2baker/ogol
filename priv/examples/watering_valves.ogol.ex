defmodule Ogol.RevisionFile.Examples.WateringValves do
  @revision %{
    kind: :ogol_revision,
    format: 2,
    app_id: "ogol_examples",
    revision: "watering_valves",
    title: "Watering Valves Example",
    exported_at: "2026-03-30T00:00:00Z",
    sources: [
      %{
        kind: :hardware_config,
        id: "hardware_config",
        module: Ogol.Generated.Hardware.Config,
        digest: "accf0e3d04a938546f8a4182178eb00de2f7db8c0268877866a2cc836da60a5f",
        title: "Watering system hardware"
      },
      %{
        kind: :machine,
        id: "watering_controller",
        module: Ogol.Generated.Machines.WateringController,
        digest: "4a2e53c59220939d5d34a58dc99fd91dc8b0aa3b7affc98ea6b07cc11c6be536",
        title: "Watering controller"
      },
      %{
        kind: :topology,
        id: "watering_system",
        module: Ogol.Generated.Topologies.WateringSystem,
        digest: "2fbc3016b0778d799173d6cdebe7c189899ca7bb60c8d3b1e41f234f8433e50c",
        title: "Watering system topology"
      }
    ]
  }
  def manifest do
    @revision
  end
end

defmodule Ogol.Generated.Machines.WateringController do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  alias Ogol.Runtime.DeliveredEvent
  alias Ogol.Runtime.Staging

  @schedule_groups [[1], [2], [3], [4]]
  @zone_outputs %{
    1 => :valve_1_open?,
    2 => :valve_2_open?,
    3 => :valve_3_open?,
    4 => :valve_4_open?
  }
  @all_outputs Map.values(@zone_outputs)
  @default_schedule_interval_ms 3_600_000
  @default_watering_duration_ms 60_000

  machine do
    name(:watering_controller)
    meaning("Four-zone watering controller with rotating schedule and manual override")
  end

  boundary do
    request(:configure_schedule,
      args: [
        interval_ms: [
          type: :integer,
          summary: "Delay between automatic watering cycles in milliseconds"
        ],
        duration_ms: [
          type: :integer,
          summary: "Watering time per active zone group in milliseconds"
        ]
      ]
    )

    request(:enable_schedule)
    request(:disable_schedule)
    request(:set_manual_valves)
    output(:valve_1_open?, :boolean, default: false, public?: true)
    output(:valve_2_open?, :boolean, default: false, public?: true)
    output(:valve_3_open?, :boolean, default: false, public?: true)
    output(:valve_4_open?, :boolean, default: false, public?: true)
    signal(:schedule_enabled)
    signal(:schedule_disabled)
    signal(:manual_override_enabled)
    signal(:watering_started)
    signal(:watering_completed)
  end

  memory do
    field(:schedule_interval_ms, :integer, default: @default_schedule_interval_ms, public?: true)
    field(:watering_duration_ms, :integer, default: @default_watering_duration_ms, public?: true)
    field(:next_group_index, :integer, default: 0, public?: true)
    field(:active_zones, :list, default: [], public?: true)
  end

  states do
    state :disabled do
      initial?(true)
      status("Schedule Disabled")
      callback(:enter_disabled)
    end

    state :auto_waiting do
      status("Waiting For Schedule")
      callback(:enter_auto_waiting)
    end

    state :auto_watering do
      status("Watering")
      callback(:enter_auto_watering)
    end

    state :manual do
      status("Manual Override")
    end
  end

  transitions do
    transition :disabled, :disabled do
      on({:request, :configure_schedule})
      callback(:configure_schedule)
    end

    transition :manual, :manual do
      on({:request, :configure_schedule})
      callback(:configure_schedule)
    end

    transition :disabled, :manual do
      on({:request, :set_manual_valves})
      priority(1)
      guard(Ogol.Machine.Helpers.callback(:valid_manual_request?))
      callback(:apply_manual_valves)
    end

    transition :manual, :manual do
      on({:request, :set_manual_valves})
      priority(1)
      guard(Ogol.Machine.Helpers.callback(:valid_manual_request?))
      callback(:apply_manual_valves)
    end

    transition :disabled, :disabled do
      on({:request, :set_manual_valves})
      callback(:reply_invalid_manual_request)
    end

    transition :manual, :manual do
      on({:request, :set_manual_valves})
      callback(:reply_invalid_manual_request)
    end

    transition :disabled, :auto_waiting do
      on({:request, :enable_schedule})
      signal(:schedule_enabled)
      reply(:ok)
    end

    transition :manual, :auto_waiting do
      on({:request, :enable_schedule})
      signal(:schedule_enabled)
      reply(:ok)
    end

    transition :disabled, :disabled do
      on({:request, :disable_schedule})
      signal(:schedule_disabled)
      reply(:ok)
    end

    transition :manual, :disabled do
      on({:request, :disable_schedule})
      signal(:schedule_disabled)
      reply(:ok)
    end

    transition :auto_waiting, :disabled do
      on({:request, :disable_schedule})
      signal(:schedule_disabled)
      reply(:ok)
    end

    transition :auto_watering, :disabled do
      on({:request, :disable_schedule})
      signal(:schedule_disabled)
      reply(:ok)
    end

    transition :auto_waiting, :auto_watering do
      on({:state_timeout, :start_watering})
    end

    transition :auto_watering, :auto_waiting do
      on({:state_timeout, :stop_watering})
      callback(:advance_schedule_group)
    end
  end

  safety do
    always(Ogol.Machine.Helpers.callback(:at_most_two_valves_open?))
  end

  def enter_disabled(_delivered, _data, staging) do
    staging
    |> close_all_zones()
    |> cancel_timeout(:start_watering)
    |> cancel_timeout(:stop_watering)
    |> set_active_zones([])
    |> ok()
  end

  def enter_auto_waiting(_delivered, data, staging) do
    staging
    |> close_all_zones()
    |> cancel_timeout(:stop_watering)
    |> set_active_zones([])
    |> schedule_timeout(:start_watering, data.fields.schedule_interval_ms)
    |> ok()
  end

  def enter_auto_watering(_delivered, data, staging) do
    zones = current_schedule_group(data)

    staging
    |> apply_zone_outputs(zones)
    |> cancel_timeout(:start_watering)
    |> set_active_zones(zones)
    |> schedule_timeout(:stop_watering, data.fields.watering_duration_ms)
    |> signal(:watering_started, %{zones: zones, next_group_index: data.fields.next_group_index})
    |> ok()
  end

  def configure_schedule(%DeliveredEvent{data: params}, _data, staging) do
    with {:ok, interval_ms} <- positive_integer(params, :interval_ms),
         {:ok, duration_ms} <- positive_integer(params, :duration_ms) do
      staging
      |> put_field(:schedule_interval_ms, interval_ms)
      |> put_field(:watering_duration_ms, duration_ms)
      |> reply(:ok)
      |> ok()
    else
      {:error, reason} ->
        staging
        |> reply({:error, reason})
        |> ok()
    end
  end

  def valid_manual_request?(%DeliveredEvent{data: params}, _data) do
    match?({:ok, _zones}, normalize_manual_zones(params))
  end

  def reply_invalid_manual_request(%DeliveredEvent{data: params}, _data, staging) do
    reason =
      case normalize_manual_zones(params) do
        {:error, reason} -> reason
        {:ok, _zones} -> :invalid_manual_request
      end

    staging
    |> reply({:error, reason})
    |> ok()
  end

  def apply_manual_valves(%DeliveredEvent{data: params}, _data, staging) do
    {:ok, zones} = normalize_manual_zones(params)

    staging
    |> cancel_timeout(:start_watering)
    |> cancel_timeout(:stop_watering)
    |> apply_zone_outputs(zones)
    |> set_active_zones(zones)
    |> signal(:manual_override_enabled, %{zones: zones})
    |> reply(:ok)
    |> ok()
  end

  def advance_schedule_group(_delivered, data, staging) do
    current_zones = current_schedule_group(data)
    next_index = rem(data.fields.next_group_index + 1, length(@schedule_groups))

    staging
    |> put_field(:next_group_index, next_index)
    |> signal(:watering_completed, %{zones: current_zones, next_group_index: next_index})
    |> ok()
  end

  def at_most_two_valves_open?(_state_name, data) do
    data.outputs
    |> Map.take(@all_outputs)
    |> Map.values()
    |> Enum.count(&(&1 == true)) <= 2
  end

  defp current_schedule_group(data) do
    @schedule_groups
    |> Enum.at(data.fields.next_group_index, [])
  end

  defp normalize_manual_zones(%{zones: zones}) when is_list(zones) do
    zones
    |> Enum.uniq()
    |> validate_manual_zones()
  end

  defp normalize_manual_zones(_params), do: {:error, :invalid_manual_zones}

  defp validate_manual_zones(zones) do
    cond do
      length(zones) > 2 -> {:error, :too_many_manual_zones}
      Enum.any?(zones, &(!Map.has_key?(@zone_outputs, &1))) -> {:error, :unknown_manual_zone}
      true -> {:ok, zones}
    end
  end

  defp positive_integer(params, key) do
    case Map.get(params, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_schedule_value, key}}
    end
  end

  defp apply_zone_outputs(staging, zones) do
    active_outputs = MapSet.new(Enum.map(zones, &Map.fetch!(@zone_outputs, &1)))

    Enum.reduce(@all_outputs, staging, fn output, acc ->
      stage_output(acc, output, MapSet.member?(active_outputs, output))
    end)
  end

  defp close_all_zones(staging), do: apply_zone_outputs(staging, [])
  defp set_active_zones(staging, zones), do: put_field(staging, :active_zones, zones)

  defp put_field(staging, name, value) do
    %{staging | data: %{staging.data | fields: Map.put(staging.data.fields, name, value)}}
  end

  defp stage_output(staging, name, value) do
    %{
      staging
      | data: %{staging.data | outputs: Map.put(staging.data.outputs, name, value)},
        boundary_effects: staging.boundary_effects ++ [{:output, %{name: name, value: value}}]
    }
  end

  defp schedule_timeout(staging, name, delay_ms) do
    %{
      staging
      | boundary_effects:
          staging.boundary_effects ++
            [{:state_timeout, %{name: name, delay_ms: delay_ms, data: %{}, meta: %{}}}]
    }
  end

  defp cancel_timeout(staging, name) do
    %{
      staging
      | boundary_effects: staging.boundary_effects ++ [{:cancel_timeout, %{name: name}}]
    }
  end

  defp signal(staging, name, data) do
    %{
      staging
      | boundary_effects:
          staging.boundary_effects ++ [{:signal, %{name: name, data: data, meta: %{}}}]
    }
  end

  defp reply(%Staging{request_from: nil} = staging, _value), do: staging

  defp reply(staging, value) do
    %{
      staging
      | reply_count: staging.reply_count + 1,
        otp_actions: staging.otp_actions ++ [{:reply, staging.request_from, value}]
    }
  end

  defp ok(staging), do: {:ok, staging}
end

defmodule Ogol.Generated.Hardware.Config do
  @ogol_hardware_definition %{
    __struct__: Ogol.Hardware.Config,
    id: "watering_hardware",
    inserted_at: nil,
    label: "Watering System Hardware",
    meta: %{
      form: %{
        "bind_ip" => "127.0.0.1",
        "domains" => [
          %{
            "cycle_time_us" => "1000",
            "id" => "main",
            "miss_threshold" => "1000",
            "recovery_threshold" => "3"
          }
        ],
        "frame_timeout_ms" => "20",
        "id" => "ethercat_demo",
        "label" => "EtherCAT Demo Ring",
        "primary_interface" => "",
        "scan_poll_ms" => "10",
        "scan_stable_ms" => "20",
        "secondary_interface" => "",
        "simulator_ip" => "127.0.0.2",
        "slaves" => [
          %{
            "driver" => "Ogol.Hardware.EtherCAT.Driver.EK1100",
            "health_poll_ms" => "250",
            "name" => "coupler",
            "process_data_domain" => "",
            "process_data_mode" => "none",
            "target_state" => "op"
          },
          %{
            "driver" => "Ogol.Hardware.EtherCAT.Driver.EL1809",
            "health_poll_ms" => "250",
            "name" => "inputs",
            "process_data_domain" => "main",
            "process_data_mode" => "all",
            "target_state" => "op"
          },
          %{
            "driver" => "Ogol.Hardware.EtherCAT.Driver.EL2809",
            "health_poll_ms" => "250",
            "name" => "outputs",
            "process_data_domain" => "main",
            "process_data_mode" => "all",
            "target_state" => "op"
          }
        ],
        "transport" => "udp"
      }
    },
    protocol: :ethercat,
    spec: %{
      __struct__: Ogol.Hardware.Config.EtherCAT,
      domains: [
        %{
          __struct__: Ogol.Hardware.Config.EtherCAT.Domain,
          cycle_time_us: 1000,
          id: :main,
          miss_threshold: 1000,
          recovery_threshold: 3
        }
      ],
      slaves: [
        %{
          __struct__: EtherCAT.Slave.Config,
          aliases: %{},
          config: %{},
          driver: Ogol.Hardware.EtherCAT.Driver.EK1100,
          health_poll_ms: 250,
          name: :coupler,
          process_data: :none,
          sync: nil,
          target_state: :op
        },
        %{
          __struct__: EtherCAT.Slave.Config,
          aliases: %{},
          config: %{},
          driver: Ogol.Hardware.EtherCAT.Driver.EL1809,
          health_poll_ms: 250,
          name: :inputs,
          process_data: {:all, :main},
          sync: nil,
          target_state: :op
        },
        %{
          __struct__: EtherCAT.Slave.Config,
          aliases: %{
            ch1: :valve_1_open?,
            ch2: :valve_2_open?,
            ch3: :valve_3_open?,
            ch4: :valve_4_open?
          },
          config: %{},
          driver: Ogol.Hardware.EtherCAT.Driver.EL2809,
          health_poll_ms: 250,
          name: :outputs,
          process_data: {:all, :main},
          sync: nil,
          target_state: :op
        }
      ],
      timing: %{
        __struct__: Ogol.Hardware.Config.EtherCAT.Timing,
        frame_timeout_ms: 20,
        scan_poll_ms: 10,
        scan_stable_ms: 20
      },
      transport: %{
        __struct__: Ogol.Hardware.Config.EtherCAT.Transport,
        bind_ip: {127, 0, 0, 1},
        mode: :udp,
        primary_interface: nil,
        secondary_interface: nil,
        simulator_ip: {127, 0, 0, 2}
      }
    },
    updated_at: nil
  }
  def definition do
    @ogol_hardware_definition
  end

  def ensure_ready do
    Ogol.Hardware.EtherCAT.Adapter.ensure_ready(definition())
  end

  def stop do
    Ogol.Hardware.EtherCAT.Adapter.stop()
  end
end

defmodule Ogol.Generated.Topologies.WateringSystem do
  use Ogol.Topology

  topology do
    strategy(:one_for_one)
    meaning("Four-zone watering system topology")
  end

  machines do
    machine(:watering_controller, Ogol.Generated.Machines.WateringController,
      restart: :permanent,
      meaning: "Rotating watering controller",
      wiring: [
        outputs: [
          valve_1_open?: :valve_1_open?,
          valve_2_open?: :valve_2_open?,
          valve_3_open?: :valve_3_open?,
          valve_4_open?: :valve_4_open?
        ]
      ]
    )
  end
end
