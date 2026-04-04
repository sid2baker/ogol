defmodule Ogol.Runtime.Hardware.ContextTest do
  use ExUnit.Case, async: false

  alias EtherCAT.Driver.{EK1100, EL1809, EL2809}
  alias EtherCAT.Master
  alias EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware.EtherCAT
  alias Ogol.Hardware.EtherCAT.{Domain, Timing, Transport}
  alias Ogol.Runtime.Hardware.Context, as: HardwareContext
  alias Ogol.Runtime.{EventLog, Notification}
  alias Ogol.TestSupport.EthercatHmiFixture

  setup do
    EventLog.reset()
    EthercatHmiFixture.stop_all!()
    wait_for_idle!()

    on_exit(fn ->
      EventLog.reset()
      EthercatHmiFixture.stop_all!()
      wait_for_idle!()
    end)

    :ok
  end

  test "builds expected-no-hardware testing context when no runtime is active" do
    ethercat = %{
      state: {:ok, :idle},
      bus: {:ok, nil},
      dc_status: {:ok, %{lock_state: :unknown}},
      reference_clock: {:ok, nil},
      last_failure: {:ok, nil},
      domains: {:ok, []},
      slaves: [],
      hardware_snapshots: [],
      protocols: []
    }

    context = HardwareContext.build(ethercat, [], [])

    assert context.summary.state == :expected_none
    assert context.observed.source == :none
    assert context.observed.backend_kind == :none
    assert context.observed.truth_source == :snapshot
    assert context.observed.hardware_expectation == :none
    assert context.observed.topology_match == :match
    assert context.mode.kind == :testing
    assert context.mode.write_policy == :enabled
    assert context.mode.authority_scope == :draft_and_simulation
    assert context.pre_arm.status == :blocked
    assert context.section_order == [:simulation, :master]
  end

  test "builds simulated testing context from an active simulation config" do
    EthercatHmiFixture.boot_preop_ring!()

    config = %EtherCAT{
      id: "packaging_line",
      label: "Packaging Line",
      transport: %Transport{
        mode: :udp,
        bind_ip: {127, 0, 0, 1},
        primary_interface: nil,
        secondary_interface: nil
      },
      timing: %Timing{
        scan_stable_ms: 20,
        scan_poll_ms: 10,
        frame_timeout_ms: 20
      },
      domains: [
        %Domain{
          id: :main,
          cycle_time_us: 1_000,
          miss_threshold: 1_000,
          recovery_threshold: 3
        }
      ],
      slaves: [
        %SlaveConfig{name: :coupler, driver: EK1100, target_state: :preop, process_data: :none},
        %SlaveConfig{name: :inputs, driver: EL1809, target_state: :preop, process_data: :none},
        %SlaveConfig{name: :outputs, driver: EL2809, target_state: :preop, process_data: :none}
      ]
    }

    event =
      Notification.new(:hardware_simulation_started,
        payload: %{config_id: config.id},
        meta: %{bus: :ethercat, config_id: config.id}
      )

    ethercat = Ogol.Runtime.Hardware.Gateway.ethercat_session()
    context = HardwareContext.build(ethercat, [event], [config])

    assert context.summary.state == :simulated
    assert context.observed.source == :simulator
    assert context.observed.backend_kind == :simulated
    assert context.observed.truth_source == :simulator
    assert context.observed.topology_match == :match
    assert context.mode.kind == :testing
    assert context.mode.write_policy == :enabled
    assert context.mode.authority_scope == :draft_and_simulation
    assert context.pre_arm.status == :blocked
    assert context.commissioning.config_id == "packaging_line"
    assert Enum.sort(context.commissioning.expected_devices) == ["coupler", "inputs", "outputs"]
    assert Enum.sort(context.commissioning.actual_devices) == ["coupler", "inputs", "outputs"]

    assert context.section_order == [
             :simulation,
             :master,
             :commissioning,
             :status,
             :devices,
             :diagnostics
           ]
  end

  test "simulation lifecycle keeps simulator context active even when the master is stopped" do
    config = %EtherCAT{
      id: "packaging_line",
      label: "Packaging Line",
      transport: %Transport{
        mode: :udp,
        bind_ip: {127, 0, 0, 1},
        primary_interface: nil,
        secondary_interface: nil
      },
      timing: %Timing{
        scan_stable_ms: 20,
        scan_poll_ms: 10,
        frame_timeout_ms: 20
      },
      domains: [
        %Domain{
          id: :main,
          cycle_time_us: 1_000,
          miss_threshold: 1_000,
          recovery_threshold: 3
        }
      ],
      slaves: [
        %SlaveConfig{name: :coupler, driver: EK1100, target_state: :preop, process_data: :none},
        %SlaveConfig{name: :inputs, driver: EL1809, target_state: :preop, process_data: :none},
        %SlaveConfig{name: :outputs, driver: EL2809, target_state: :preop, process_data: :none}
      ]
    }

    event =
      Notification.new(:hardware_simulation_started,
        payload: %{config_id: config.id},
        meta: %{bus: :ethercat, config_id: config.id}
      )

    ethercat = %{
      state: {:ok, :idle},
      bus: {:ok, nil},
      dc_status: {:ok, %{lock_state: :unknown}},
      reference_clock: {:ok, nil},
      last_failure: {:ok, nil},
      domains: {:ok, []},
      slaves: [],
      hardware_snapshots: [],
      protocols: []
    }

    context = HardwareContext.build(ethercat, [event], [config])

    assert context.summary.state == :simulated
    assert context.observed.source == :simulator
    assert context.mode.kind == :testing

    assert context.section_order == [
             :simulation,
             :master,
             :commissioning,
             :status,
             :devices,
             :diagnostics
           ]
  end

  test "live hardware defaults to armed mode" do
    ethercat = %{
      state: {:ok, :preop_ready},
      bus: {:ok, %{transport: :ethercat}},
      dc_status: {:ok, %{lock_state: :locked}},
      reference_clock: {:ok, %{name: :coupler, station: 0}},
      last_failure: {:ok, nil},
      domains: {:ok, [{:main, 1_000, %{}}]},
      slaves: [%{fault: nil, snapshot: {:ok, %{faults: []}}}],
      hardware_snapshots: [%{last_feedback_at: System.system_time(:millisecond)}],
      protocols: []
    }

    context = HardwareContext.build(ethercat, [], [])

    assert context.summary.state == :live_healthy
    assert context.observed.source == :live
    assert context.mode.kind == :armed
    assert context.mode.armable?
    assert context.mode.write_policy == :confirmed
    assert context.mode.authority_scope == :live_runtime_changes
    assert context.pre_arm.status == :ready

    assert context.section_order == [
             :master,
             :status,
             :capture,
             :devices,
             :diagnostics,
             :provisioning
           ]
  end

  test "live hardware in testing is presented as live inspect posture internally" do
    now_ms = System.system_time(:millisecond)

    ethercat = %{
      state: {:ok, :preop_ready},
      bus: {:ok, %{transport: :ethercat}},
      dc_status: {:ok, %{lock_state: :locked}},
      reference_clock: {:ok, %{name: :coupler, station: 0}},
      last_failure: {:ok, nil},
      domains: {:ok, [{:main, 1_000, %{}}]},
      slaves: [%{fault: nil, snapshot: {:ok, %{faults: []}}}],
      hardware_snapshots: [%{last_feedback_at: now_ms}],
      protocols: []
    }

    context = HardwareContext.build(ethercat, [], [], mode: :testing, now_ms: now_ms)

    assert context.observed.source == :live
    assert context.mode.kind == :testing
    assert context.mode.write_policy == :restricted
    assert context.mode.authority_scope == :capture_and_compare
    assert context.pre_arm.status == :ready
    assert context.section_order == [:master, :status, :capture, :devices, :diagnostics]
  end

  test "armed mode falls back to testing when no live source exists" do
    ethercat = %{
      state: {:ok, :idle},
      bus: {:ok, nil},
      dc_status: {:ok, %{lock_state: :unknown}},
      reference_clock: {:ok, nil},
      last_failure: {:ok, nil},
      domains: {:ok, []},
      slaves: [],
      hardware_snapshots: [],
      protocols: []
    }

    context = HardwareContext.build(ethercat, [], [], mode: :armed)

    assert context.mode.kind == :testing
    assert context.mode.write_policy == :enabled
    assert context.pre_arm.status == :blocked
  end

  test "live hardware with stale truth blocks the arm check" do
    now_ms = System.system_time(:millisecond)

    ethercat = %{
      state: {:ok, :idle},
      bus: {:ok, nil},
      dc_status: {:ok, %{lock_state: :unknown}},
      reference_clock: {:ok, nil},
      last_failure: {:ok, nil},
      domains: {:ok, []},
      slaves: [],
      hardware_snapshots: [%{last_feedback_at: now_ms - 5_000}],
      protocols: []
    }

    context = HardwareContext.build(ethercat, [], [], mode: :testing, now_ms: now_ms)

    assert context.pre_arm.status == :blocked
    assert context.pre_arm.detail =~ "hardware freshness is not live"
  end

  defp wait_for_idle!(attempts \\ 20)

  defp wait_for_idle!(0) do
    assert match?(
             %Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle],
             Master.status()
           )
  end

  defp wait_for_idle!(attempts) do
    case Master.status() do
      %Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle] ->
        :ok

      _other ->
        Process.sleep(25)
        wait_for_idle!(attempts - 1)
    end
  end
end
