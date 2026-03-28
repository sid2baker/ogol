defmodule Ogol.HMI.HardwareGatewayTest do
  use ExUnit.Case, async: false

  alias Ogol.HMI.{
    HardwareConfigStore,
    HardwareGateway,
    HardwareReleaseStore,
    HardwareSupportSnapshotStore,
    MachineSnapshot,
    SnapshotStore,
    SurfaceDeployment,
    SurfaceDeploymentStore,
    SurfaceDraftStore,
    TopologySnapshot
  }

  alias Ogol.TestSupport.EthercatHmiFixture

  setup do
    HardwareConfigStore.reset()
    HardwareReleaseStore.reset()
    HardwareSupportSnapshotStore.reset()
    SurfaceDraftStore.reset()
    SurfaceDeploymentStore.reset()
    SnapshotStore.reset()
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      HardwareConfigStore.reset()
      HardwareReleaseStore.reset()
      HardwareSupportSnapshotStore.reset()
      SurfaceDraftStore.reset()
      SurfaceDeploymentStore.reset()
      SnapshotStore.reset()
      EthercatHmiFixture.stop_all!()
    end)

    :ok
  end

  test "captures the current ethercat ring as a reusable hardware config" do
    EthercatHmiFixture.boot_preop_ring!()

    assert {:ok, config} =
             HardwareGateway.capture_ethercat_hardware_config(%{
               "id" => "captured_line",
               "label" => "Captured Line"
             })

    assert config.id == "captured_line"
    assert config.label == "Captured Line"
    assert config.meta[:captured_from][:source] == :live_ethercat
    assert Enum.map(config.spec.slaves, & &1.name) == [:coupler, :inputs, :outputs]
    assert length(config.spec.domains) == 1
    assert %{} = config.meta[:form]

    assert %{} = HardwareConfigStore.get_config("captured_line")
  end

  test "previews the current ethercat ring without saving it" do
    EthercatHmiFixture.boot_preop_ring!()

    assert {:ok, config} =
             HardwareGateway.preview_ethercat_hardware_config(%{
               "id" => "preview_line",
               "label" => "Preview Line"
             })

    assert config.id == "preview_line"
    assert config.label == "Preview Line"
    assert config.meta[:captured_from][:source] == :live_ethercat
    assert Enum.map(config.spec.slaves, & &1.name) == [:coupler, :inputs, :outputs]
    assert HardwareConfigStore.get_config("preview_line") == nil
  end

  test "starts a simulator directly from a quick draft config" do
    assert {:ok, runtime} =
             HardwareGateway.start_simulation_config(%{
               "id" => "draft_ring",
               "label" => "Draft Ring",
               "slaves" => %{
                 "0" => %{"name" => "coupler", "driver" => "EtherCAT.Driver.EK1100"},
                 "1" => %{"name" => "inputs", "driver" => "EtherCAT.Driver.EL1809"}
               }
             })

    assert runtime.config.id == "draft_ring"
    assert runtime.slaves == [:coupler, :inputs]
    assert {:ok, :preop_ready} = EtherCAT.state()
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
             HardwareGateway.preview_ethercat_simulation_config(
               HardwareGateway.default_ethercat_simulation_form()
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

  test "compares candidate and armed runtime bundles, not only the hardware config" do
    assert {:ok, config} =
             HardwareGateway.preview_ethercat_simulation_config(
               HardwareGateway.default_ethercat_simulation_form()
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
        root_machine_id: :line,
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
             HardwareGateway.preview_ethercat_simulation_config(
               HardwareGateway.default_ethercat_simulation_form()
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
