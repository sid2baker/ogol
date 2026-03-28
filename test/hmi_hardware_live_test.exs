defmodule Ogol.HMI.HardwareLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.HMI.{
    HardwareGateway,
    HardwareSnapshot,
    MachineSnapshot,
    SnapshotStore,
    SurfaceDeployment,
    TopologySnapshot
  }

  alias Ogol.TestSupport.EthercatHmiFixture

  setup do
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      EthercatHmiFixture.stop_all!()
    end)

    :ok
  end

  test "renders the hardware page without an active ethercat session" do
    {:ok, _view, html} = live(build_conn(), "/studio/hardware")

    assert html =~ "Hardware Studio"
    assert html =~ "Expected No Hardware"
    assert html =~ "Draft / Test"
    assert html =~ "Source"
    assert html =~ "Authority"
    assert html =~ "Draft And Simulation"
    assert html =~ "Simulation"
    assert html =~ "Simulator cell"
    assert html =~ "Master cell"
    assert html =~ "Armed Gate"
    assert html =~ "live hardware is not connected"
    assert html =~ "hardware-context-compact"
    refute html =~ "hardware-context-runtime-health"
    refute html =~ "hardware-context-fault-scope"
  end

  test "no-hardware mode shows the quick simulator editor without low-level ethercat fields" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    rendered = render(view)
    assert rendered =~ "Draft / Test"
    assert rendered =~ "No Backend"
    assert rendered =~ "Run simulator draft"
    assert rendered =~ "Generated Runtime Plan"
    assert rendered =~ "Master cell"
    assert rendered =~ "master-config-form"
    refute rendered =~ "Target State"
    refute rendered =~ "Process Data"
    refute rendered =~ "Health Poll ms"
  end

  test "simulation driver selects keep their chosen values across re-render" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    rendered =
      view
      |> form("[data-test='simulation-config-form']", %{
        "simulation_config" => %{
          "id" => "ethercat_demo",
          "label" => "EtherCAT Demo Ring",
          "slaves" => %{
            "0" => %{
              "name" => "coupler",
              "driver" => "EtherCAT.Driver.EK1100"
            },
            "1" => %{
              "name" => "inputs",
              "driver" => "EtherCAT.Driver.EL1809"
            },
            "2" => %{
              "name" => "outputs",
              "driver" => "EtherCAT.Driver.EL2809"
            }
          }
        }
      })
      |> render_change()

    assert Regex.match?(
             ~r/<option[^>]*(value="EtherCAT.Driver.EK1100"[^>]*selected|selected[^>]*value="EtherCAT.Driver.EK1100")/,
             rendered
           )

    assert Regex.match?(
             ~r/<option[^>]*(value="EtherCAT.Driver.EL2809"[^>]*selected|selected[^>]*value="EtherCAT.Driver.EL2809")/,
             rendered
           )
  end

  test "simulation editor exposes only quick ring-shape fields" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    assert has_element?(view, "select[name='simulation_config[slaves][0][driver]']")
    refute has_element?(view, "input[name='simulation_config[slaves][0][driver]']")

    assert has_element?(
             view,
             "select[name='simulation_config[slaves][0][driver]'] option[value='EtherCAT.Driver.EK1100']"
           )

    assert has_element?(
             view,
             "select[name='simulation_config[slaves][1][driver]'] option[value='EtherCAT.Driver.EL1809']"
           )

    assert has_element?(
             view,
             "select[name='simulation_config[slaves][2][driver]'] option[value='EtherCAT.Driver.EL2809']"
           )

    refute has_element?(view, "select[name='simulation_config[slaves][0][target_state]']")
    refute has_element?(view, "select[name='simulation_config[slaves][0][process_data_domain]']")
    refute has_element?(view, "input[name='simulation_config[slaves][0][health_poll_ms]']")
    assert has_element?(view, "input[name='simulation_config[bind_ip]']")
    assert has_element?(view, "input[name='simulation_config[simulator_ip]']")
    assert has_element?(view, "input[name='simulation_config[scan_stable_ms]']")
    assert has_element?(view, "input[name='simulation_config[frame_timeout_ms]']")
  end

  test "hardware cells can toggle between cell and code views" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    refute has_element?(view, "[data-test='simulation-cell-code']")
    refute has_element?(view, "[data-test='master-cell-code']")

    view
    |> element("[data-test='hardware-cell-mode-simulation-code']")
    |> render_click()

    assert has_element?(view, "[data-test='simulation-cell-code']")
    assert render(view) =~ "simulator_cell do"

    view
    |> element("[data-test='hardware-cell-mode-master-code']")
    |> render_click()

    assert has_element?(view, "[data-test='master-cell-code']")
    assert render(view) =~ "master_cell do"
  end

  test "draft/test mode remains active through the explicit mode controls" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    view
    |> element("[data-test='hardware-mode-testing']")
    |> render_click()

    assert_patch(view, "/studio/hardware?mode=testing")

    rendered = render(view)
    assert rendered =~ "Draft / Test"
    assert rendered =~ "No Backend"
    assert rendered =~ "Write Policy"
  end

  test "promotes the current draft to a hardware candidate" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    assert render(view) =~ "Candidate vs Armed"

    view
    |> element("[data-test='promote-draft-candidate']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "candidate c1 promoted"
    assert rendered =~ "c1"
    assert rendered =~ "ethercat_demo"
  end

  test "no-hardware mode keeps release posture compact" do
    {:ok, _view, html} = live(build_conn(), "/studio/hardware")

    assert html =~ "Candidate vs Armed"
    assert html =~ "Compact view while no live hardware is connected."
    assert html =~ "Release History"
    refute html =~ "Machine Diff"
    refute html =~ "Topology Diff"
    refute html =~ "Panel Diff"
  end

  test "renders candidate vs armed bundle drift from runtime snapshots and panel assignment" do
    assert {:ok, config} =
             HardwareGateway.preview_ethercat_simulation_config(
               HardwareGateway.default_ethercat_simulation_form()
             )

    assert {:ok, _candidate} = HardwareGateway.promote_candidate_config(config)
    assert {:ok, _release} = HardwareGateway.arm_candidate_release()

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

    {:ok, _view, html} = live(build_conn(), "/studio/hardware")

    assert html =~ "Machine Diff"
    assert html =~ "Topology Diff"
    assert html =~ "Panel Diff"
    assert html =~ "line"
    assert html =~ "line_topology"
    assert html =~ "surface_id: candidate=operations_station armed=operations_overview"
  end

  test "shows release history for previously armed releases" do
    assert {:ok, config} =
             HardwareGateway.preview_ethercat_simulation_config(
               HardwareGateway.default_ethercat_simulation_form()
             )

    assert {:ok, _candidate} = HardwareGateway.promote_candidate_config(config)
    assert {:ok, _release} = HardwareGateway.arm_candidate_release()
    assert {:ok, _candidate} = HardwareGateway.promote_candidate_config(config)
    assert {:ok, _release} = HardwareGateway.arm_candidate_release()

    {:ok, _view, html} = live(build_conn(), "/studio/hardware")

    assert html =~ "Release History"
    assert html =~ "0.1.0"
    assert html =~ "0.1.1"
  end

  test "captures a runtime snapshot from the diagnostics section" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/hardware?mode=testing")

    view
    |> element("[data-test='capture-runtime-snapshot']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "Runtime Snapshot captured"
    assert rendered =~ "Saved Snapshots"
    assert rendered =~ "Runtime Snapshot"
    assert rendered =~ "Selected Snapshot"
    assert rendered =~ "Recent Events"
    assert rendered =~ "Download JSON"
  end

  test "armed requests without live hardware fall back to testing" do
    {:ok, _view, html} = live(build_conn(), "/studio/hardware?mode=armed")

    assert html =~ "Draft / Test"
    assert html =~ "Expected No Hardware"
    assert html =~ "Simulation"
    assert html =~ "Armed Gate"
    assert html =~ "live hardware is not connected"
  end

  test "simulator-backed sessions stay in testing mode" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/hardware?mode=armed")

    assert_eventually(fn ->
      rendered = render(view)
      {simulation_pos, _} = :binary.match(rendered, "data-test=\"hardware-section-simulation\"")
      {master_pos, _} = :binary.match(rendered, "data-test=\"hardware-section-master\"")

      assert rendered =~ "Simulated"
      assert rendered =~ "Draft / Test"
      assert rendered =~ "Draft And Simulation"
      assert rendered =~ "Current simulator state"
      assert rendered =~ "Current master state"
      assert has_element?(view, "[data-test='simulation-activate-master']")
      assert simulation_pos < master_pos
      refute rendered =~ "Use connected hardware as a config baseline"
    end)
  end

  test "simulator-backed sessions do not expose the live capture comparison" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/hardware?mode=testing")

    assert_eventually(fn ->
      rendered = render(view)
      refute rendered =~ "Draft vs Live"
      refute rendered =~ "Capture / Baseline"
    end)
  end

  test "live-ish hardware without a preview fails closed when cloning to draft" do
    :ok =
      SnapshotStore.put_hardware(%HardwareSnapshot{
        bus: :ethercat,
        endpoint_id: :coupler,
        connected?: true,
        last_feedback_at: System.system_time(:millisecond)
      })

    {:ok, view, _html} = live(build_conn(), "/studio/hardware?mode=testing")

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Draft vs Live"
      assert rendered =~ "No live hardware preview is available."
    end)

    view
    |> element("[data-test='clone-live-to-draft']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "clone live to draft failed"
  end

  test "stale hardware snapshots do not block simulator authoring" do
    :ok =
      SnapshotStore.put_hardware(%HardwareSnapshot{
        bus: :ethercat,
        endpoint_id: :coupler,
        connected?: true,
        last_feedback_at: System.system_time(:millisecond) - 10_000
      })

    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    rendered = render(view)
    assert rendered =~ "No Backend"
    assert rendered =~ "Simulation"

    view
    |> element("[data-test='add-simulation-slave']")
    |> render_click()

    assert render(view) =~ "Slave 4"
  end

  test "saves a hardware config and starts an ethercat simulation from it" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    view
    |> form("[data-test='simulation-config-form']", %{
      "simulation_config" => %{
        "id" => "packaging_line",
        "label" => "Packaging Line",
        "slaves" => %{
          "0" => %{
            "name" => "coupler",
            "driver" => "EtherCAT.Driver.EK1100"
          },
          "1" => %{
            "name" => "inputs",
            "driver" => "EtherCAT.Driver.EL1809"
          },
          "2" => %{
            "name" => "outputs",
            "driver" => "EtherCAT.Driver.EL2809"
          }
        }
      }
    })
    |> render_submit()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "saved hardware config packaging_line"
      assert rendered =~ "Packaging Line"
      assert rendered =~ "Start simulation"
    end)

    view
    |> form("[data-test='simulation-config-form']", %{
      "simulation_config" => %{
        "id" => "scratch",
        "label" => "Scratch",
        "slaves" => %{
          "0" => %{
            "name" => "outputs",
            "driver" => "EtherCAT.Driver.EL2809"
          }
        }
      }
    })
    |> render_change()

    assert render(view) =~ "value=\"scratch\""

    view
    |> element("[data-test='load-simulation-config-packaging_line']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "loaded packaging_line into the simulator editor"
    assert rendered =~ "value=\"packaging_line\""

    view
    |> element("[data-test='start-simulation-packaging_line']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "starting simulation from packaging_line"

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation started from packaging_line"
      assert rendered =~ "Simulated"
      refute rendered =~ "live hardware is present and freshness is current"
      assert rendered =~ "Current simulator state"
      assert rendered =~ "Current master state"
      assert rendered =~ "preop_ready"
      assert rendered =~ "coupler"
      assert rendered =~ "inputs"
      assert rendered =~ "outputs"

      assert {:ok, :preop_ready} = EtherCAT.state()
      assert {:ok, slaves} = EtherCAT.slaves()
      assert Enum.sort(slaves) == [:coupler, :inputs, :outputs]
    end)
  end

  test "runs the staged simulator draft without saving it first" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    view
    |> element("[data-test='remove-simulation-slave-2']")
    |> render_click()

    rendered =
      view
      |> form("[data-test='simulation-config-form']", %{
        "simulation_config" => %{
          "id" => "draft_ring",
          "label" => "Draft Ring",
          "slaves" => %{
            "0" => %{"name" => "coupler", "driver" => "EtherCAT.Driver.EK1100"},
            "1" => %{"name" => "inputs", "driver" => "EtherCAT.Driver.EL1809"}
          }
        }
      })
      |> render_change()

    assert rendered =~ "draft_ring"

    rendered =
      view
      |> element("[data-test='start-simulation-draft']")
      |> render_click()

    assert rendered =~ "starting simulation from draft_ring"

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation started from draft_ring"
      assert rendered =~ "Simulated"
      assert rendered =~ "Current simulator state"
      assert {:ok, :preop_ready} = EtherCAT.state()
      assert {:ok, slaves} = EtherCAT.slaves()
      assert Enum.sort(slaves) == [:coupler, :inputs]
    end)
  end

  test "running simulator flow hides provisioning-style editing and stays state-first" do
    EthercatHmiFixture.boot_preop_ring!()

    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "Current simulator state"
      assert rendered =~ "Current master state"
      refute rendered =~ "Per-slave PREOP configuration"
      refute has_element?(view, "[data-test='slave-config-outputs']")
    end)
  end

  test "preop simulation stays stable when activate is clicked" do
    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    view
    |> form("[data-test='simulation-config-form']", %{
      "simulation_config" => %{
        "id" => "preop_only",
        "label" => "PREOP Only",
        "slaves" => %{
          "0" => %{"name" => "coupler", "driver" => "EtherCAT.Driver.EK1100"},
          "1" => %{"name" => "inputs", "driver" => "EtherCAT.Driver.EL1809"},
          "2" => %{"name" => "outputs", "driver" => "EtherCAT.Driver.EL2809"}
        }
      }
    })
    |> render_submit()

    view
    |> element("[data-test='start-simulation-preop_only']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation started from preop_only"
      assert rendered =~ "Current master state"
      assert {:ok, :preop_ready} = EtherCAT.state()
    end)

    Process.sleep(350)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "preop_ready"
      assert {:ok, :preop_ready} = EtherCAT.state()
      refute rendered =~ "EtherCAT activate failed"
    end)

    view
    |> element("[data-test='simulation-activate-master']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "EtherCAT activate sent"
      assert rendered =~ "preop_ready"
      assert {:ok, :preop_ready} = EtherCAT.state()
      refute rendered =~ "EtherCAT activate failed"
      refute rendered =~ ":recovery_in_progress"
    end)
  end

  test "running simulation switches to the current-state stop control" do
    assert {:ok, _config} =
             HardwareGateway.save_ethercat_simulation_config(
               HardwareGateway.default_ethercat_simulation_form()
               |> Map.put("id", "running_card")
               |> Map.put("label", "Running Card")
             )

    {:ok, view, _html} = live(build_conn(), "/studio/hardware")

    view
    |> element("[data-test='start-simulation-running_card']")
    |> render_click()

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='simulation-stop-current']")
      refute has_element?(view, "[data-test='start-simulation-running_card']")
      assert {:ok, :preop_ready} = EtherCAT.state()
    end)

    view
    |> element("[data-test='simulation-stop-current']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simulation stopped for running_card"
      assert rendered =~ "Expected No Hardware"
      assert has_element?(view, "[data-test='start-simulation-running_card']")
      refute has_element?(view, "[data-test='stop-simulation-running_card']")
    end)
  end

  defp assert_eventually(fun, attempts \\ 30)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError] ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end
end
