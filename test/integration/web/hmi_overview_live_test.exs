defmodule Ogol.HMI.SurfaceLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.TestSupport.SimpleHmiDemo
  alias Ogol.HMI.Surface.Deployments, as: SurfaceDeployment
  alias Ogol.HMI.Surface.DeploymentStore, as: SurfaceDeploymentStore
  alias Ogol.HMI.Surface.RuntimeStore, as: SurfaceRuntimeStore
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture
  alias Ogol.TestSupport.SlowRequestMachine
  alias Ogol.TestSupport.SampleMachine
  alias OgolWeb.Layouts

  @example_id "pump_skid_commissioning_bench"
  @sequence_id "pump_skid_commissioning"
  @overview_route "/ops/hmis/operations_overview/overview"

  setup do
    SurfaceRuntimeStore.reset()
    SurfaceDeploymentStore.reset()
    :ok = Session.reset_runtime()
    :ok = Session.reset_loaded_revision()
    :ok = Session.reset_machines()
    :ok = Session.reset_sequences()
    :ok = Session.reset_topologies()
    :ok = Session.reset_hardware()
    :ok = Session.reset_simulator_configs()
    :ok = Session.reset_hmi_surfaces()
    :ok
  end

  test "renders the assigned runtime surface with machine snapshots and recent events" do
    {:ok, view, html} = live(build_conn(), @overview_route)
    assert html =~ "data-test=\"surface-screen-overview\""
    refute html =~ "Ogol Runtime Surface"

    {:ok, pid} = SampleMachine.start_link()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "sample_machine"
      assert rendered =~ "idle"
      assert rendered =~ "Controls"
    end)

    view
    |> element("[data-test='control-sample_machine-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "started"
      assert rendered =~ "machine started"
      assert rendered =~ "state entered"
      assert rendered =~ "operator skill invoked"
    end)
  end

  test "renders the fallback surface launcher and direct runtime route" do
    assignment = SurfaceDeployment.default_assignment()

    {:ok, _view, html} = live(build_conn(), "/ops/hmis")

    assert html =~ "Runtime Surfaces"
    assert html =~ to_string(assignment.surface_id)
    assert html =~ to_string(assignment.panel_id)

    {:ok, _view, direct_html} =
      live(build_conn(), "/ops/hmis/#{assignment.surface_id}/#{assignment.default_screen}")

    assert direct_html =~ "data-test=\"surface-screen-procedures\""
    assert direct_html =~ "data-test=\"surface-screen-tab-overview\""

    {:ok, _view, overview_html} = live(build_conn(), "/ops/hmis/operations_overview/overview")

    assert overview_html =~ "data-test=\"surface-screen-overview\""
    assert overview_html =~ "data-test=\"surface-screen-tab-procedures\""

    {:ok, _view, station_html} = live(build_conn(), "/ops/hmis/operations_station/station")

    assert station_html =~ "data-test=\"surface-screen-station\""
    refute station_html =~ "Ogol Runtime Surface"
  end

  test "dispatches request and event controls from the overview" do
    {:ok, view, _html} = live(build_conn(), @overview_route)

    {:ok, pid} = SimpleHmiDemo.boot!()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simple_hmi_line"
      assert rendered =~ "start"
      assert rendered =~ "part seen"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "operator skill invoked"
      assert rendered =~ "reply=ok"
      assert rendered =~ "running"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-part_seen']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "operator skill invoked"
      assert rendered =~ "reply=accepted"
      assert rendered =~ "part_counted"
      assert rendered =~ "part_count"
    end)
  end

  test "denies overview operator controls while Auto is armed" do
    {:ok, view, _html} = live(build_conn(), @overview_route)

    {:ok, pid} = SimpleHmiDemo.boot!()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='control-simple_hmi_line-skill-start']")
    end)

    assert :ok = Session.set_control_mode(:auto)

    view
    |> element("[data-test='control-simple_hmi_line-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simple_hmi_line :: skill start"
      assert rendered =~ "reason=auto_mode_armed"
      refute rendered =~ "reply=ok"
    end)
  end

  test "selects and starts a procedure from the overview panel" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, @sequence_id})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
      assert Session.runtime_state().deployment_id
    end)

    {:ok, view, _html} = live(build_conn(), "/ops")

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='procedure-panel']")
      assert has_element?(view, "[data-test='procedure-select-#{@sequence_id}']")
    end)

    view
    |> element("[data-test='procedure-select-#{@sequence_id}']")
    |> render_click()

    assert_eventually(fn ->
      assert Session.selected_procedure_id() == @sequence_id
    end)

    view
    |> element("[data-test='procedure-arm-auto']")
    |> render_click()

    assert_eventually(fn ->
      assert Session.control_mode() == :auto
    end)

    view
    |> element("[data-test='procedure-run-selected']")
    |> render_click()

    assert_eventually(fn ->
      assert Session.sequence_run_state().status in [:starting, :running]
      assert match?({:sequence_run, _run_id}, Session.sequence_owner())
    end)
  end

  test "requests manual takeover from the overview panel" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, @sequence_id})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
      assert Session.runtime_state().deployment_id
    end)

    assert :ok = Session.select_procedure(@sequence_id)
    assert :ok = Session.set_control_mode(:auto)
    assert :ok = Session.start_sequence_run(@sequence_id)

    assert_eventually(fn ->
      assert Session.sequence_run_state().status in [:starting, :running, :paused]
    end)

    {:ok, view, _html} = live(build_conn(), "/ops")

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='procedure-request-manual-takeover']")
    end)

    view
    |> element("[data-test='procedure-request-manual-takeover']")
    |> render_click()

    assert_eventually(
      fn ->
        assert Session.control_mode() == :manual
        assert Session.sequence_owner() == :manual_operator
        assert Session.sequence_run_state().status == :aborted
      end,
      160
    )
  end

  test "toggles procedure run policy from the overview panel" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, @sequence_id})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
    end)

    {:ok, view, _html} = live(build_conn(), "/ops")

    assert_eventually(fn ->
      assert has_element?(view, "[data-test='procedure-set-cycle-policy']")
    end)

    view
    |> element("[data-test='procedure-set-cycle-policy']")
    |> render_click()

    assert_eventually(fn ->
      assert Session.sequence_run_state().policy == :cycle
      assert has_element?(view, "[data-test='procedure-set-once-policy']")
    end)

    view
    |> element("[data-test='procedure-set-once-policy']")
    |> render_click()

    assert_eventually(fn ->
      assert Session.sequence_run_state().policy == :once
      assert has_element?(view, "[data-test='procedure-set-cycle-policy']")
    end)
  end

  test "clears a completed procedure result from the overview panel" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, @sequence_id})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
    end)

    {:ok, view, _html} = live(build_conn(), "/ops")

    view
    |> element("[data-test='procedure-select-#{@sequence_id}']")
    |> render_click()

    view
    |> element("[data-test='procedure-arm-auto']")
    |> render_click()

    view
    |> element("[data-test='procedure-run-selected']")
    |> render_click()

    assert_eventually(
      fn ->
        assert Session.sequence_run_state().status == :completed
        assert has_element?(view, "[data-test='procedure-clear-result']")
      end,
      200
    )

    view
    |> element("[data-test='procedure-clear-result']")
    |> render_click()

    assert_eventually(fn ->
      assert Session.sequence_run_state().status == :idle
      refute render(view) =~ "Last result"
    end)
  end

  test "adapter feedback events show fact and channel labels in the overview stream" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
    end)

    {:ok, view, _html} = live(build_conn(), @overview_route)

    assert {:ok, :ok} = Session.invoke_machine(:alarm_stack, :show_running)

    assert_eventually(
      fn ->
        html = render(view)
        assert html =~ "adapter feedback"
        assert html =~ "signal=green_fb?"
        assert html =~ "channel=ch4"
      end,
      120
    )
  end

  test "operator request dispatch does not block the liveview while machine is busy" do
    {:ok, view, _html} = live(build_conn(), @overview_route)

    {:ok, pid} = SlowRequestMachine.start_link()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "slow_request_machine"
      assert rendered =~ "start"
    end)

    view
    |> element("[data-test='control-slow_request_machine-skill-start']")
    |> render_click()

    rendered = render(view)
    assert rendered =~ "invoking skill"
    assert rendered =~ "slow_request_machine :: skill start"

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "reply=ok"
      assert rendered =~ "running"
      assert rendered =~ "operator skill invoked"
    end)
  end

  test "renders the runtime surface without app-shell navigation chrome" do
    {:ok, view, _html} = live(build_conn(), "/ops")

    refute has_element?(view, "aside")
    assert has_element?(view, "[data-test='surface-screen-procedures']")
    assert has_element?(view, "[data-test='surface-screen-tab-overview']")
    assert has_element?(view, "[data-test='surface-screen-tab-procedures']")
    refute render(view) =~ "Studio"
  end

  test "renders a station surface and dispatches focused machine skills" do
    {:ok, pid} = SimpleHmiDemo.boot!()

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    SurfaceDeployment.assign_panel(:primary_runtime_panel, :operations_station)

    {:ok, view, html} = live(build_conn(), "/ops")

    assert html =~ "data-test=\"surface-screen-station\""

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "simple_hmi_line"
      assert rendered =~ "start"
      assert rendered =~ "part seen"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-start']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "running"
      assert rendered =~ "operator skill invoked"
    end)

    view
    |> element("[data-test='control-simple_hmi_line-skill-part_seen']")
    |> render_click()

    assert_eventually(fn ->
      rendered = render(view)
      assert rendered =~ "part_counted"
      assert rendered =~ "reply=accepted"
    end)
  end

  test "uses an accessible active mode tab treatment in the app header" do
    html =
      render_component(&Layouts.app/1, %{
        inner_content: "",
        hmi_mode: :ops,
        hmi_nav: :surfaces,
        page_title: "Operations",
        page_summary:
          "Triage-first runtime supervision for machines, hardware, and recent incidents."
      })

    assert html =~
             "bg-[var(--app-info-strong)] px-4 py-2 font-mono text-[11px] font-semibold uppercase tracking-[0.22em] text-[var(--app-shell)]"

    assert html =~ "aria-current=\"page\""
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError] ->
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
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
end
