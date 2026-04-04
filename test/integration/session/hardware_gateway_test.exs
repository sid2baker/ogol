defmodule Ogol.Runtime.Hardware.GatewayTest do
  use Ogol.SessionIntegrationCase, async: false

  alias EtherCAT.Backend
  alias EtherCAT.Master
  alias EtherCAT.Simulator
  alias EtherCAT.Simulator.Status, as: SimulatorStatus
  alias Ogol.Hardware.EtherCAT
  alias Ogol.Hardware.EtherCAT.Session, as: EtherCATSession
  alias Ogol.Simulator.Config.EtherCAT, as: EtherCATSimulatorConfig

  alias Ogol.HMI.Surface.Deployments, as: SurfaceDeployment
  alias Ogol.HMI.Surface.DeploymentStore, as: SurfaceDeploymentStore
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore

  alias Ogol.Runtime
  alias Ogol.Runtime.{MachineSnapshot, SnapshotStore, TopologySnapshot}
  alias Ogol.Runtime.Hardware.Gateway, as: HardwareGateway
  alias Ogol.Runtime.Hardware.ReleaseStore, as: HardwareReleaseStore
  alias Ogol.Runtime.Hardware.SupportSnapshotStore, as: HardwareSupportSnapshotStore
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.TestSupport.EthercatRuntimeHelper
  alias Ogol.TestSupport.WorkspaceFixture
  alias Ogol.Session

  setup do
    :ok = Session.reset_loaded_revision()
    :ok = Session.reset_hardware()
    HardwareReleaseStore.reset()
    HardwareSupportSnapshotStore.reset()
    SurfaceRuntimeStore.reset()
    SurfaceDeploymentStore.reset()
    SnapshotStore.reset()
    EthercatHmiFixture.stop_all!()
    {:ok, _revision_file, _report} = WorkspaceFixture.load_packaging_line!()
    :ok = Session.reset_loaded_revision()

    on_exit(fn ->
      :ok = Session.reset_loaded_revision()
      :ok = Session.reset_hardware()
      HardwareReleaseStore.reset()
      HardwareSupportSnapshotStore.reset()
      SurfaceRuntimeStore.reset()
      SurfaceDeploymentStore.reset()
      SnapshotStore.reset()
      EthercatHmiFixture.stop_all!()
    end)

    :ok
  end

  test "captures the current ethercat ring as a reusable hardware" do
    EthercatHmiFixture.boot_preop_ring!()

    assert {:ok, config} =
             HardwareGateway.capture_ethercat_hardware(%{
               "id" => "captured_line",
               "label" => "Captured Line"
             })

    assert config.id == "captured_line"
    assert config.label == "Captured Line"
    assert config.meta[:captured_from][:source] == :live_ethercat
    assert EtherCAT.transport_mode(config) == :udp
    assert config.meta[:form]["transport"] == "udp"
    assert Enum.map(config.slaves, & &1.name) == [:coupler, :inputs, :outputs]
    assert length(config.domains) == 1
    assert %{} = config.meta[:form]

    current_config = Session.fetch_hardware_model("ethercat")
    assert current_config.id == "captured_line"
    assert is_map(current_config.meta)
  end

  test "previews the current ethercat ring without saving it" do
    EthercatHmiFixture.boot_preop_ring!()

    assert {:ok, config} =
             HardwareGateway.preview_ethercat_hardware(%{
               "id" => "preview_line",
               "label" => "Preview Line"
             })

    assert config.id == "preview_line"
    assert config.label == "Preview Line"
    assert config.meta[:captured_from][:source] == :live_ethercat
    assert Enum.map(config.slaves, & &1.name) == [:coupler, :inputs, :outputs]
    assert Session.fetch_hardware_model("ethercat").id != "preview_line"
  end

  test "starts a simulator directly from a quick draft config" do
    assert {:ok, runtime} =
             HardwareGateway.start_simulation_config(%{
               "transport" => "udp",
               "host" => "127.0.0.2",
               "port" => "0",
               "devices" => %{
                 "0" => %{"name" => "coupler", "driver" => "Ogol.Hardware.EtherCAT.Driver.EK1100"},
                 "1" => %{"name" => "inputs", "driver" => "Ogol.Hardware.EtherCAT.Driver.EL1809"},
                 "2" => %{"name" => "outputs", "driver" => "Ogol.Hardware.EtherCAT.Driver.EL2809"}
               },
               "connections" => %{
                 "0" => %{
                   "source_device" => "outputs",
                   "source_signal" => "ch1",
                   "target_device" => "inputs",
                   "target_signal" => "ch1"
                 }
               }
             })

    assert runtime.config.adapter == :ethercat
    assert runtime.slaves == [:coupler, :inputs, :outputs]
    assert runtime.connections == [%{source: {:outputs, :ch1}, target: {:inputs, :ch1}}]
    assert is_integer(runtime.port)
    assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: port}}} = Simulator.status()
    assert port == runtime.port
    assert {:ok, [%{source: {:outputs, :ch1}, target: {:inputs, :ch1}}]} = Simulator.connections()

    assert match?(
             %Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle],
             Master.status()
           )
  end

  test "default ethercat simulator form exposes host, devices, and loopback wires" do
    form = HardwareGateway.default_ethercat_simulator_form()

    assert form["transport"] == "udp"
    assert form["host"] == "127.0.0.2"
    assert form["port"] == "0"
    refute Map.has_key?(form, "bind_ip")
    assert Enum.map(form["devices"], & &1["name"]) == ["coupler", "inputs", "outputs"]

    assert hd(form["connections"]) == %{
             "source_device" => "outputs",
             "source_signal" => "ch1",
             "target_device" => "inputs",
             "target_signal" => "ch1"
           }
  end

  test "simulator preview accepts raw socket transport" do
    form =
      HardwareGateway.default_ethercat_simulator_form()
      |> Map.put("transport", "raw")
      |> Map.put("primary_interface", "eth-test0")

    assert {:ok, config} = HardwareGateway.preview_ethercat_simulator_config(form)
    assert EtherCATSimulatorConfig.transport_mode(config) == :raw
    assert EtherCATSimulatorConfig.primary_interface(config) == "eth-test0"
    assert EtherCATSimulatorConfig.secondary_interface(config) == nil
  end

  test "simulator preview accepts redundant raw transport" do
    form =
      HardwareGateway.default_ethercat_simulator_form()
      |> Map.put("transport", "redundant")
      |> Map.put("primary_interface", "eth-test0")
      |> Map.put("secondary_interface", "eth-test1")

    assert {:ok, config} = HardwareGateway.preview_ethercat_simulator_config(form)
    assert EtherCATSimulatorConfig.transport_mode(config) == :redundant
    assert EtherCATSimulatorConfig.primary_interface(config) == "eth-test0"
    assert EtherCATSimulatorConfig.secondary_interface(config) == "eth-test1"
  end

  test "scans the current bus into the master form while preserving transport fields" do
    assert {:ok, _runtime} =
             HardwareGateway.start_simulation_config(
               HardwareGateway.default_ethercat_simulator_form()
             )

    assert {:ok, form} =
             HardwareGateway.scan_ethercat_master_form(%{
               "id" => "ethercat_demo",
               "label" => "EtherCAT Demo Ring",
               "bind_ip" => "127.0.0.9",
               "scan_stable_ms" => "45",
               "scan_poll_ms" => "25",
               "frame_timeout_ms" => "55"
             })

    assert form["bind_ip"] == "127.0.0.9"
    refute Map.has_key?(form, "simulator_ip")
    assert form["scan_stable_ms"] == "45"
    assert form["scan_poll_ms"] == "25"
    assert form["frame_timeout_ms"] == "55"
    assert Enum.map(form["domains"], & &1["id"]) == ["main"]
    assert Enum.map(form["slaves"], & &1["name"]) == ["coupler", "inputs", "outputs"]
    assert Enum.map(form["slaves"], & &1["target_state"]) == ["op", "op", "op"]
  end

  test "starts and stops the ethercat master without stopping the simulator" do
    EthercatHmiFixture.boot_preop_ring!()

    assert :ok = HardwareGateway.stop_ethercat_master()

    assert match?(
             %Master.Status{lifecycle: lifecycle} when lifecycle in [:stopped, :idle],
             Master.status()
           )

    assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()

    assert {:ok, runtime} =
             HardwareGateway.start_ethercat_master(
               HardwareGateway.default_ethercat_hardware_form()
             )

    assert runtime.config.id == "ethercat_demo"
    assert runtime.slaves == [:coupler, :inputs, :outputs]
    assert runtime.state == :operational
    assert %Master.Status{lifecycle: :operational} = Master.status()
  end

  test "compiled workspace hardware exposes executable runtime entrypoints" do
    assert {:ok, _status} = Runtime.compile(:hardware, "ethercat")

    assert {:ok, module} = Runtime.current(:hardware, "ethercat")

    assert %Ogol.Hardware.EtherCAT{} = runtime_config = module.hardware()
    EthercatHmiFixture.boot_simulator_only!()
    :ok = EthercatRuntimeHelper.ensure_started!()
    assert {:ok, runtime} = EtherCATSession.start_master(runtime_config)

    assert runtime.config.id == "ethercat_demo"
    assert runtime.state == :operational
    assert runtime.slaves == [:coupler, :inputs, :outputs]
    assert %Master.Status{lifecycle: :operational} = Master.status()
    assert {:ok, %SimulatorStatus{backend: %Backend.Udp{port: _port}}} = Simulator.status()
    assert :ok = EtherCATSession.stop_master()
  end

  test "captures a support snapshot without mutating runtime artifacts" do
    assert {:ok, snapshot} =
             HardwareGateway.capture_support_snapshot(%{
               context: %{
                 mode: %{kind: :testing, write_policy: :enabled},
                 observed: %{source: :none},
                 summary: %{state: :expected_none}
               },
               ethercat: %{slaves: [], state: {:ok, :idle}},
               events: [],
               saved_configs: []
             })

    assert snapshot.kind == :support
    assert snapshot.summary.mode == :testing
    assert snapshot.summary.source == :none
    assert snapshot.summary.state == :expected_none
    assert [%{id: id}] = HardwareGateway.list_support_snapshots()
    assert id == snapshot.id
    assert %{id: ^id} = HardwareGateway.get_support_snapshot(id)
  end

  test "promotes a draft to candidate and arms an immutable release" do
    assert {:ok, config} =
             HardwareGateway.preview_ethercat_hardware_form(
               HardwareGateway.default_ethercat_hardware_form()
             )

    assert {:ok, candidate} = HardwareGateway.promote_candidate_config(config)
    assert candidate.build_id == "c1"
    assert candidate.config.id == "ethercat_demo"

    assert {:ok, release} = HardwareGateway.arm_candidate_release()
    assert release.version == "0.1.0"
    assert release.bump == :minor
    assert release.candidate_build_id == "c1"
    assert release.config.id == "ethercat_demo"
  end

  test "compares candidate and armed runtime bundles, not only the hardware" do
    assert {:ok, config} =
             HardwareGateway.preview_ethercat_hardware_form(
               HardwareGateway.default_ethercat_hardware_form()
             )

    assert {:ok, _candidate} = HardwareGateway.promote_candidate_config(config)
    assert {:ok, initial_release} = HardwareGateway.arm_candidate_release()
    assert initial_release.version == "0.1.0"

    :ok =
      SnapshotStore.put_machine(%MachineSnapshot{
        machine_id: :line,
        module: __MODULE__,
        health: :healthy
      })

    :ok =
      SnapshotStore.put_topology(%TopologySnapshot{
        topology_id: :line_topology,
        health: :healthy
      })

    SurfaceDeployment.assign_panel(:primary_runtime_panel, :operations_station)

    assert {:ok, _candidate} = HardwareGateway.promote_candidate_config(config)

    diff = HardwareGateway.candidate_vs_armed_diff()

    assert diff.bump == :major
    assert diff.status == :different
    assert diff.candidate_only_machines == ["line"]
    assert diff.candidate_only_topologies == ["line_topology"]
    assert Enum.any?(diff.panel_mismatches, &String.contains?(&1, "surface_id:"))
  end

  test "can roll back the armed release to an earlier immutable version" do
    assert {:ok, config} =
             HardwareGateway.preview_ethercat_hardware_form(
               HardwareGateway.default_ethercat_hardware_form()
             )

    assert {:ok, _candidate} = HardwareGateway.promote_candidate_config(config)
    assert {:ok, release_one} = HardwareGateway.arm_candidate_release()
    assert release_one.version == "0.1.0"

    assert {:ok, _candidate} = HardwareGateway.promote_candidate_config(config)
    assert {:ok, release_two} = HardwareGateway.arm_candidate_release()
    assert release_two.version == "0.1.1"

    assert {:ok, rolled_back} = HardwareGateway.rollback_armed_release("0.1.0")
    assert rolled_back.version == "0.1.0"
    assert HardwareGateway.current_armed_release().version == "0.1.0"
  end
end
