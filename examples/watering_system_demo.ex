defmodule Ogol.Examples.WateringSystemDemo do
  @moduledoc """
  EtherCAT simulator-backed watering controller example.

  The controller drives four irrigation valves with two key constraints:

  - it rotates through one zone at a time on a simple recurring schedule
  - it never allows more than two valves to be open in parallel

  The machine also supports schedule disable/manual override flows so an operator
  can turn on up to two zones directly.

  In IEx:

      iex -S mix
      demo = Ogol.Examples.WateringSystemDemo.boot!(signal_sink: self())
      {:ok, :ok} = Ogol.Examples.WateringSystemDemo.configure_schedule(demo, 3_600_000, 60_000)
      {:ok, :ok} = Ogol.Examples.WateringSystemDemo.enable_schedule(demo)
      flush()
      Ogol.Examples.WateringSystemDemo.snapshot()
      {:ok, :ok} = Ogol.Examples.WateringSystemDemo.disable_schedule(demo)
      {:ok, :ok} = Ogol.Examples.WateringSystemDemo.set_manual_zones(demo, [2, 4])
      Ogol.Examples.WateringSystemDemo.snapshot()
      Ogol.Examples.WateringSystemDemo.stop(demo)
  """

  alias EtherCAT.Backend
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias EtherCAT.Simulator.Slave, as: SimulatorSlave
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware.EtherCAT.Driver.EL2809
  alias Ogol.Runtime.DeliveredEvent
  alias Ogol.Runtime.Staging

  @master_ip {127, 0, 0, 1}
  @simulator_ip {127, 0, 0, 2}
  @boot_ready_timeout_ms 500
  @type demo :: %{
          machine: pid(),
          simulator: pid(),
          simulator_port: :inet.port_number()
        }

  defmodule Controller do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    @schedule_groups [[1], [2], [3], [4]]
    @zone_outputs %{1 => :valve_1_open?, 2 => :valve_2_open?, 3 => :valve_3_open?, 4 => :valve_4_open?}
    @all_outputs Map.values(@zone_outputs)
    @default_schedule_interval_ms 3_600_000
    @default_watering_duration_ms 60_000

    machine do
      name(:watering_controller)
      meaning("Four-zone watering controller with rotating schedule and manual override")

      hardware_ref([
        %{
          slave: :outputs,
          outputs: [:valve_1_open?, :valve_2_open?, :valve_3_open?, :valve_4_open?]
        }
      ])
    end

    boundary do
      request(:configure_schedule)
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
          boundary_effects:
            staging.boundary_effects ++ [{:output, %{name: name, value: value}}]
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
        | boundary_effects:
            staging.boundary_effects ++ [{:cancel_timeout, %{name: name}}]
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

  @spec boot!(keyword()) :: demo()
  def boot!(opts \\ []) do
    signal_sink = Keyword.get(opts, :signal_sink, self())
    _ = EtherCAT.stop()
    _ = Simulator.stop()

    {:ok, simulator} =
      Simulator.start(
        devices: [
          SimulatorSlave.from_driver(EL2809, name: :outputs)
        ],
        backend: {:udp, %{host: @simulator_ip, port: 0}}
      )

    {:ok, %SimulatorStatus{backend: %Backend.Udp{port: port}}} = Simulator.status()

    :ok =
      EtherCAT.start(
        backend: {:udp, %{host: @simulator_ip, bind_ip: @master_ip, port: port}},
        dc: nil,
        domains: [[id: :main, cycle_time_us: 1_000]],
        slaves: [
          %SlaveConfig{
            name: :outputs,
            driver: EL2809,
            aliases: %{
              ch1: :valve_1_open?,
              ch2: :valve_2_open?,
              ch3: :valve_3_open?,
              ch4: :valve_4_open?
            },
            process_data: {:all, :main},
            target_state: :op,
            health_poll_ms: nil
          }
        ],
        scan_stable_ms: 20,
        scan_poll_ms: 10,
        frame_timeout_ms: 20
      )

    :ok = EtherCAT.await_operational(2_000)

    case Master.status() do
      %Master.Status{lifecycle: :operational} -> :ok
      other -> raise "expected operational master, got: #{inspect(other)}"
    end

    {:ok, machine} = Controller.start_link(signal_sink: signal_sink)
    :ok = await_snapshot(%{valve_1: false, valve_2: false, valve_3: false, valve_4: false})

    %{machine: machine, simulator: simulator, simulator_port: port}
  end

  @spec configure_schedule(demo() | pid(), pos_integer(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def configure_schedule(demo_or_pid, interval_ms, duration_ms)
      when is_integer(interval_ms) and interval_ms > 0 and is_integer(duration_ms) and
             duration_ms > 0 do
    invoke(demo_or_pid, :configure_schedule, %{interval_ms: interval_ms, duration_ms: duration_ms})
  end

  @spec enable_schedule(demo() | pid()) :: {:ok, term()} | {:error, term()}
  def enable_schedule(demo_or_pid), do: invoke(demo_or_pid, :enable_schedule)

  @spec disable_schedule(demo() | pid()) :: {:ok, term()} | {:error, term()}
  def disable_schedule(demo_or_pid), do: invoke(demo_or_pid, :disable_schedule)

  @spec set_manual_zones(demo() | pid(), [pos_integer()]) :: {:ok, term()} | {:error, term()}
  def set_manual_zones(demo_or_pid, zones) when is_list(zones) do
    invoke(demo_or_pid, :set_manual_valves, %{zones: zones})
  end

  @spec invoke(demo() | pid(), atom(), map()) :: {:ok, term()} | {:error, term()}
  def invoke(demo_or_pid, request, args \\ %{}) when is_atom(request) and is_map(args) do
    Ogol.Runtime.Delivery.invoke(machine_pid(demo_or_pid), request, args)
  end

  @spec machine_pid(demo() | pid()) :: pid()
  def machine_pid(%{machine: pid}) when is_pid(pid), do: pid
  def machine_pid(pid) when is_pid(pid), do: pid

  @spec snapshot() :: %{valve_1: boolean(), valve_2: boolean(), valve_3: boolean(), valve_4: boolean()}
  def snapshot do
    {:ok, valve_1} = Simulator.get_value(:outputs, :ch1)
    {:ok, valve_2} = Simulator.get_value(:outputs, :ch2)
    {:ok, valve_3} = Simulator.get_value(:outputs, :ch3)
    {:ok, valve_4} = Simulator.get_value(:outputs, :ch4)

    %{valve_1: valve_1, valve_2: valve_2, valve_3: valve_3, valve_4: valve_4}
  end

  @spec stop() :: :ok | {:error, term()}
  def stop do
    _ = EtherCAT.stop()
    Simulator.stop()
  end

  @spec stop(demo() | nil) :: :ok | {:error, term()}
  def stop(%{machine: pid}) when is_pid(pid) do
    stop_machine(pid)
    stop()
  end

  def stop(_demo), do: stop()

  defp await_snapshot(expected) do
    deadline = System.monotonic_time(:millisecond) + @boot_ready_timeout_ms
    do_await_snapshot(expected, deadline)
  end

  defp do_await_snapshot(expected, deadline) do
    if snapshot() == expected do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, {:boot_snapshot_timeout, snapshot()}}
      else
        Process.sleep(10)
        do_await_snapshot(expected, deadline)
      end
    end
  end

  defp stop_machine(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.unlink(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> :ok
      end
    else
      :ok
    end
  end
end
