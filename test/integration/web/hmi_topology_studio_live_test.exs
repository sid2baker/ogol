defmodule Ogol.HMI.TopologyStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Examples
  alias Ogol.Session.Revisions
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.TestSupport.HmiStudioTopology
  alias Ogol.Topology.Source, as: TopologySource

  @example_id "pump_skid_commissioning_bench"

  test "renders the topology studio page for a selected topology" do
    {:ok, view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Topology Studio"
    assert html =~ "Packaging Line topology"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "Live"
    assert has_element?(view, "[data-test='topology-view-visual']")
    assert has_element?(view, "[data-test='topology-view-live']")
    refute html =~ ">New<"
  end

  test "switches to source mode in place for the selected topology" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_click(view, "select_view", %{"view" => "source"})

    assert_patch(view, "/studio/topology/source")

    html = render(view)

    assert html =~ "defmodule Ogol.Generated.Topologies.PackagingLine do"
    assert html =~ "use Ogol.Topology"
  end

  test "draft topology studio ignores the active runtime and stays on the current workspace" do
    {:ok, runtime_pid} =
      apply(Ogol.Topology.Runtime, :start, [HmiStudioTopology.__ogol_topology__()])

    on_exit(fn ->
      if Process.alive?(runtime_pid), do: GenServer.stop(runtime_pid, :shutdown)
    end)

    {:ok, _view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Packaging Line topology"
    assert html =~ "packaging_line"
    refute html =~ "Simple HMI Studio Line"
  end

  test "revision query is ignored and topology still reflects the current workspace" do
    revision_model =
      Session.fetch_topology("packaging_line").model
      |> Map.put(:meaning, "Packaging Line Revision Topology")

    Session.save_topology_source(
      "packaging_line",
      Ogol.Topology.Source.to_source(revision_model),
      revision_model,
      :synced,
      []
    )

    assert {:ok, %Revisions.Revision{id: "r1"}} =
             Revisions.deploy_current(app_id: "ogol")

    draft_model =
      Session.fetch_topology("packaging_line").model
      |> Map.put(:meaning, "Packaging Line Draft Topology")

    Session.save_topology_source(
      "packaging_line",
      Ogol.Topology.Source.to_source(draft_model),
      draft_model,
      :synced,
      []
    )

    assert :ok = Session.set_desired_runtime(:stopped)

    {:ok, runtime_pid} =
      apply(Ogol.Topology.Runtime, :start, [HmiStudioTopology.__ogol_topology__()])

    on_exit(fn ->
      if Process.alive?(runtime_pid), do: GenServer.stop(runtime_pid, :shutdown)
    end)

    {:ok, _view, html} = live(build_conn(), "/studio/topology?revision=r1")

    assert html =~ "Packaging Line Draft Topology"
    refute html =~ "Packaging Line Revision Topology"
    refute html =~ "Simple HMI Studio Line"

    assert Session.fetch_topology("packaging_line").model.meaning ==
             "Packaging Line Draft Topology"
  end

  test "machine module selection lists available machine drafts" do
    {:ok, view, html} = live(build_conn(), "/studio/topology")

    assert html =~ ~s(select name="topology[machines][0][module_name]")
    assert html =~ ~s(value="Ogol.Generated.Machines.PackagingLine")
    assert html =~ ~s(value="Ogol.Generated.Machines.InspectionCell")
    assert html =~ "Inspection cell coordinator (inspection_cell)"
    assert has_element?(view, ~s(select[name="topology[machines][0][module_name]"]))
  end

  test "start stays clickable and explains why it is blocked before compile" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    refute has_element?(view, ~s(button[phx-value-transition="start"][disabled]))

    render_click(view, "request_transition", %{"transition" => "start"})

    html = render(view)

    assert html =~ "Start blocked"
    assert html =~ "Compile the current topology source before starting it."
  end

  test "adds a new machine draft to the selected topology from the visual editor" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_click(view, "add_topology_machine", %{})

    assert Session.fetch_machine("machine_1")
    assert has_element?(view, ~s(input[name="topology[machines][1][name]"][value="machine_1"]))

    assert has_element?(
             view,
             ~s(select[name="topology[machines][1][module_name]"] option[selected][value="Ogol.Generated.Machines.Machine1"])
           )

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    assert html =~ "machine(:machine_1, Ogol.Generated.Machines.Machine1"
  end

  test "removes a topology machine row in place" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_click(view, "add_topology_machine", %{})
    render_click(view, "remove_topology_machine", %{"index" => "1"})

    refute has_element?(view, ~s(input[name="topology[machines][1][name]"][value="machine_1"]))

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    refute html =~ "machine(:machine_1, Ogol.Generated.Machines.Machine1"
  end

  test "starts and stops the selected topology from the studio cell actions" do
    boot_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})

    assert %{topology_scope: :packaging_line} = Ogol.Topology.Registry.active_topology()
    assert has_element?(view, ~s(button[phx-value-transition="stop"]))
    assert render(view) =~ "Running"

    render_click(view, "request_transition", %{"transition" => "stop"})

    html = render(view)

    assert html =~ "Start"
    refute html =~ "Stop"
    assert Ogol.Topology.Registry.active_topology() == nil
  end

  test "udp topology start tells the user to start simulator first when it is not running" do
    assert :ok = Session.set_desired_runtime(:stopped)
    EthercatHmiFixture.stop_all!()

    assert {:ok, _example, _revision_file, _report} =
             Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})

    html = render(view)

    assert html =~ "The current hardware uses UDP simulator transport."
    assert html =~ "Start the simulator on the Simulator page before starting this topology."
  end

  test "running topology exposes apply and redeploys through the action boundary" do
    boot_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})

    first_deployment_id = Session.runtime_state().deployment_id

    assert has_element?(view, ~s(button[phx-value-transition="apply"]))

    render_click(view, "request_transition", %{"transition" => "apply"})

    assert %{topology_scope: :packaging_line} = Ogol.Topology.Registry.active_topology()
    assert Session.runtime_state().deployment_id != first_deployment_id
  end

  test "live mode renders running machine instances as tabs and invokes a skill on the selected instance" do
    topology_model = %{
      module_name: "Ogol.Generated.Topologies.PackagingAndInspection",
      strategy: "one_for_one",
      meaning: "Packaging and inspection runtime",
      machines: [
        %{
          name: "packaging_line",
          module_name: "Ogol.Generated.Machines.PackagingLine",
          restart: "permanent",
          meaning: "Packaging line"
        },
        %{
          name: "inspection_cell",
          module_name: "Ogol.Generated.Machines.InspectionCell",
          restart: "transient",
          meaning: "Inspection cell"
        }
      ]
    }

    Session.create_topology("packaging_and_inspection")

    Session.save_topology_source(
      "packaging_and_inspection",
      TopologySource.to_source(topology_model),
      topology_model,
      :synced,
      []
    )

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})
    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(fn ->
      assert %{topology_scope: :packaging_and_inspection} =
               Ogol.Topology.Registry.active_topology()

      assert has_element?(view, "[data-test='topology-live-machine-packaging_line']")
      assert has_element?(view, "[data-test='topology-live-machine-inspection_cell']")
    end)

    render_click(view, "select_live_machine", %{"machine" => "packaging_line"})

    html = render(view)

    assert html =~ "topology-live-machine-mermaid-packaging_line"
    assert html =~ "stateDiagram-v2"

    refute html =~
             "Parse the selected machine into the supported model to render the live state diagram here."

    render_submit(view, "invoke_live_skill", %{
      "machine" => "packaging_line",
      "skill" => "start",
      "args" => %{}
    })

    assert_eventually(fn ->
      html = render(view)

      assert html =~ "packaging_line :: skill start"
      assert html =~ "reply=:ok"
      assert html =~ "class state_running ogolActive"
    end)
  end

  test "commissioning example start uses its imported hardware" do
    assert {:ok, _example, _revision_file, _report} =
             Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_simulator_only!()

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})

    assert_eventually(fn ->
      assert %{topology_scope: :pump_skid_bench} = Ogol.Topology.Registry.active_topology()
    end)
  end

  test "commissioning example exposes typed live skill args" do
    assert {:ok, _example, _revision_file, _report} =
             Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    boot_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})
    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(
      fn ->
        assert %{topology_scope: :pump_skid_bench} = Ogol.Topology.Registry.active_topology()
        assert has_element?(view, "[data-test='topology-live-machine-alarm_stack']")
      end,
      80
    )

    render_click(view, "select_live_machine", %{"machine" => "alarm_stack"})

    assert_eventually(
      fn ->
        assert has_element?(view, "[data-test='topology-live-skill-alarm_stack-show_running']")
        assert has_element?(view, "[data-test='topology-live-skill-alarm_stack-show_fault']")
        assert has_element?(view, "[data-test='topology-live-skill-alarm_stack-clear']")
      end,
      80
    )

    render_submit(view, "invoke_live_skill", %{
      "machine" => "alarm_stack",
      "skill" => "show_fault",
      "args" => %{}
    })

    Process.sleep(50)

    html = render(view)

    assert html =~ "alarm_stack :: skill show_fault"
    assert html =~ "reply=:ok"
    refute html =~ "{:invalid_schedule_value, :interval_ms}"
  end

  test "live manual skill dispatch is denied while Auto is armed" do
    assert {:ok, _example, _revision_file, _report} =
             Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    boot_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    compile_topology(view)
    render_click(view, "request_transition", %{"transition" => "start"})
    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(
      fn ->
        assert %{topology_scope: :pump_skid_bench} = Ogol.Topology.Registry.active_topology()
        assert has_element?(view, "[data-test='topology-live-machine-alarm_stack']")
      end,
      80
    )

    render_click(view, "select_live_machine", %{"machine" => "alarm_stack"})

    assert_eventually(
      fn ->
        assert has_element?(view, "[data-test='topology-live-skill-alarm_stack-show_fault']")
      end,
      80
    )

    assert :ok = Session.set_control_mode(:auto)

    render_submit(view, "invoke_live_skill", %{
      "machine" => "alarm_stack",
      "skill" => "show_fault",
      "args" => %{}
    })

    assert_eventually(
      fn ->
        html = render(view)
        assert html =~ "alarm_stack :: skill show_fault"
        assert html =~ "reason=:auto_mode_armed"
      end,
      80
    )
  end

  test "falls back to source mode when the topology source leaves the supported subset" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    unsupported_source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology
      alias Custom.Helper

      topology do
        strategy(:one_for_one)
      end

      machines do
        machine(:packaging_line, Ogol.Generated.Machines.PackagingLine)
      end
    end
    """

    render_change(view, "change_source", %{"draft" => %{"source" => unsupported_source}})

    html = render(view)

    assert html =~ "Visual editor unavailable"
    assert html =~ "must only define `use`, `topology`, and `machines`"
    assert html =~ "alias Custom.Helper"
  end

  test "loads persisted parser diagnostics without crashing the topology page" do
    bad_source = """
    defmodule Ogol.Generated.Topologies.PackagingLine do
      use Ogol.Topology

      topology do
        strategy(:one_for_one)
    end
    """

    Session.save_topology_source(
      "packaging_line",
      bad_source,
      nil,
      :unsupported,
      [
        {[
           line: 5,
           column: 5,
           end_line: 6,
           end_column: 1,
           error_type: :mismatched_delimiter,
           opening_delimiter: :"(",
           closing_delimiter: :end,
           expected_delimiter: :")"
         ], "unexpected reserved word: ", "end"}
      ]
    )

    {:ok, _view, html} = live(build_conn(), "/studio/topology")

    assert html =~ "Visual editor unavailable"
    assert html =~ "Topology Studio"
  end

  test "visual edits update the selected topology draft" do
    {:ok, view, _html} = live(build_conn(), "/studio/topology")

    render_change(view, "change_visual", %{
      "topology" => %{
        "module_name" => "Ogol.Generated.Topologies.PackagingLine",
        "strategy" => "one_for_all",
        "meaning" => "Packaging line runtime topology",
        "machine_count" => "2",
        "machines" => %{
          "0" => %{
            "name" => "packaging_line",
            "module_name" => "Ogol.Generated.Machines.PackagingLine",
            "restart" => "permanent",
            "meaning" => "Packaging line coordinator"
          },
          "1" => %{
            "name" => "inspection_cell",
            "module_name" => "Ogol.Generated.Machines.InspectionCell",
            "restart" => "transient",
            "meaning" => "Inspection coordinator"
          }
        }
      }
    })

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)

    assert html =~ "Packaging line runtime topology"
    assert html =~ "strategy(:one_for_all)"
    assert html =~ "machine(:inspection_cell, Ogol.Generated.Machines.InspectionCell"
  end

  defp boot_simulator! do
    EthercatHmiFixture.boot_simulator_only!()
  end

  defp put_udp_hardware! do
    config = Session.fetch_hardware_model("ethercat")

    Session.put_hardware(%{
      config
      | transport: %{
          config.transport
          | mode: :udp,
            bind_ip: {127, 0, 0, 1},
            primary_interface: nil,
            secondary_interface: nil
        }
    })
  end

  defp compile_topology(view) do
    render_click(view, "request_transition", %{"transition" => "compile"})
  end

  defp assert_eventually(fun, attempts \\ 30)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end
end
