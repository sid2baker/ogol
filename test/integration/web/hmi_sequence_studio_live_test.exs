defmodule Ogol.HMI.SequenceStudioLiveTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Studio.Examples
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  setup do
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

  test "renders an empty sequence workspace and lets draft mode create a new sequence" do
    {:ok, _example, _revision_file, _report} = Examples.load_into_workspace(@example_id)
    :ok = Session.reset_sequences()

    {:ok, view, html} = live(build_conn(), "/studio/sequences")

    assert html =~ "Sequence Studio"
    assert html =~ "No sequences in the current workspace."
    assert has_element?(view, "button", "New")

    render_click(view, "new_sequence", %{})

    assert_patch(view, "/studio/sequences/sequence_1")

    html = render(view)
    assert html =~ "Compile"
    assert html =~ "Visual"
    assert html =~ "Source"
    assert html =~ "PumpSkidBench"
    assert html =~ "Available Machines"
    assert html =~ "transfer_pump"
    assert html =~ "Skills"
    assert html =~ "Status"
    assert html =~ "Signals"
    assert html =~ "Visual Builder"
  end

  test "switches between visual and source views for a sequence draft" do
    draft = Session.create_sequence("pump_skid_manual")

    {:ok, view, html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    assert html =~ "pump_skid_manual"
    assert html =~ "Root Flow"
    assert has_element?(view, "[data-test='sequence-view-source']")

    render_click(view, "select_view", %{"view" => "source"})

    html = render(view)
    assert html =~ "defmodule Ogol.Generated.Sequences.PumpSkidManual do"
    assert html =~ "use Ogol.Sequence"
  end

  test "deleting the selected sequence patches to the next available sequence page" do
    draft = Session.create_sequence("browser_delete_sequence")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    render_click(view, "request_transition", %{"transition" => "delete"})

    expected_path =
      case Session.list_sequences() do
        [%{id: id} | _rest] -> "/studio/sequences/#{id}"
        [] -> "/studio/sequences"
      end

    assert_patch(view, expected_path)
    refute Enum.any?(Session.list_sequences(), &(&1.id == draft.id))
  end

  test "compiles the current sequence source against the current workspace topology" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    draft = Session.create_sequence("pump_skid_manual")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    render_click(view, "request_transition", %{"transition" => "compile"})

    html = render(view)

    assert html =~ "Compiled"
    assert html =~ "Compiled Canonical Model"
  end

  test "visual builder can add procedures and common steps from the current machine contract surface" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    {:ok, view, html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    assert html =~ "Visual Builder"
    assert html =~ "supply_valve"
    assert html =~ "return_valve"
    assert html =~ "transfer_pump"

    render_submit(view, "add_sequence_procedure", %{
      "procedure" => %{"name" => "alarm_reset", "meaning" => "Clear the alarm path"}
    })

    render_change(view, "change_step_builder", %{
      "builder" => %{
        "target" => "procedure",
        "target_procedure" => "alarm_reset",
        "kind" => "do_skill",
        "machine" => "alarm_stack",
        "skill" => "clear",
        "status" => "green_fb?",
        "run_procedure" => "alarm_reset",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Clear alarm stack"
      }
    })

    render_submit(view, "add_sequence_step", %{
      "builder" => %{
        "target" => "procedure",
        "target_procedure" => "alarm_reset",
        "kind" => "do_skill",
        "machine" => "alarm_stack",
        "skill" => "clear",
        "status" => "green_fb?",
        "run_procedure" => "alarm_reset",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Clear alarm stack"
      }
    })

    render_change(view, "change_step_builder", %{
      "builder" => %{
        "target" => "root",
        "target_procedure" => "alarm_reset",
        "kind" => "run",
        "machine" => "alarm_stack",
        "skill" => "clear",
        "status" => "green_fb?",
        "run_procedure" => "alarm_reset",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Run alarm reset"
      }
    })

    render_submit(view, "add_sequence_step", %{
      "builder" => %{
        "target" => "root",
        "target_procedure" => "alarm_reset",
        "kind" => "run",
        "machine" => "alarm_stack",
        "skill" => "clear",
        "status" => "green_fb?",
        "run_procedure" => "alarm_reset",
        "timeout_ms" => "",
        "fail_message" => "",
        "meaning" => "Run alarm reset"
      }
    })

    html = render(view)

    assert html =~ ":alarm_reset"
    assert html =~ "alarm_stack.clear"
    assert html =~ "Run alarm reset"

    source = Session.fetch_sequence("pump_skid_commissioning").source
    assert source =~ "proc :alarm_reset, meaning: \"Clear the alarm path\" do"
    assert source =~ "do_skill(:alarm_stack, :clear, meaning: \"Clear alarm stack\")"
    assert source =~ "run(:alarm_reset, meaning: \"Run alarm reset\")"
  end

  test "new sequences in the commissioning example target the loaded topology and expose its machine contract" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    {:ok, view, _html} = live(build_conn(), "/studio/sequences")

    render_click(view, "new_sequence", %{})

    assert_patch(view, "/studio/sequences/sequence_1")

    html = render(view)

    assert html =~ "Ogol.Generated.Topologies.PumpSkidBench"
    assert html =~ "transfer_pump"

    assert has_element?(
             view,
             ~s(select[name="builder[machine]"] option[value="transfer_pump"])
           )
  end

  test "checked-in example sequence page reflects a completed run without exposing runtime controls" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()
    refute_sequence_runtime_controls(view)
    start_sequence_run!("pump_skid_commissioning")

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Completed"
        assert html =~ "The latest sequence run finished successfully."
        assert Session.sequence_run_state().status == :completed
      end,
      200
    )

    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(fn ->
      html = render(view)
      assert html =~ "Live Run"
      assert html =~ "Control Mode"
      assert html =~ "Owner"
      assert html =~ "Auto"
      assert html =~ "Run Status"
      assert html =~ "Completed"
      assert html =~ "Current Procedure"
    end)
  end

  test "checked-in example sequence page reflects an aborted run while Auto stays armed" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()
    start_sequence_run!("pump_skid_commissioning")

    assert_eventually(fn ->
      run = Session.sequence_run_state()
      assert run.status in [:starting, :running]
      assert is_binary(run.current_step_label)
      assert String.starts_with?(run.current_step_label, "Hold ")
    end)

    assert :ok = Session.cancel_sequence_run()

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Aborted"
        assert html =~ "The latest sequence run was aborted."
        assert Session.sequence_run_state().status == :aborted
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == :manual_operator
      end,
      200
    )

    refute_sequence_runtime_controls(view)
    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(fn ->
      html = render(view)
      assert html =~ "Abort Request"
      assert html =~ "Aborted"
      assert html =~ "Auto"
      assert html =~ "Manual Operator"
    end)
  end

  test "checked-in example sequence page reflects cycle mode driven from the runtime control plane" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()
    refute_sequence_runtime_controls(view)
    start_sequence_run!("pump_skid_commissioning", policy: :cycle)

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()

        assert run.status == :running
        assert run.policy == :cycle
        assert run.cycle_count >= 1
        assert Session.sequence_owner() == {:sequence_run, run.run_id}
      end,
      320
    )

    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(fn ->
      html = render(view)
      assert html =~ "Run Policy"
      assert html =~ "Cycle"
      assert html =~ "Cycles Completed"
    end)

    assert :ok = Session.cancel_sequence_run()

    assert_eventually(fn ->
      run = Session.sequence_run_state()
      assert run.status == :aborted
      assert run.policy == :cycle
      assert run.cycle_count >= 1
      assert Session.control_mode() == :auto
      assert Session.sequence_owner() == :manual_operator
    end)
  end

  test "checked-in example sequence page reflects pause and resume driven from the runtime control plane" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()
    start_sequence_run!("pump_skid_commissioning")

    assert_eventually(fn ->
      run = Session.sequence_run_state()
      assert run.status in [:starting, :running]
      assert is_binary(run.current_step_label)
      assert String.starts_with?(run.current_step_label, "Hold ")
    end)

    assert :ok = Session.pause_sequence_run()

    assert_eventually(fn ->
      pause_intent = Session.pending_intent().pause

      assert pause_intent.requested? == true
      assert pause_intent.admitted? == true
    end)

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Paused"
        assert Session.sequence_run_state().status == :paused
      end,
      200
    )

    assert :ok = Session.resume_sequence_run()

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Completed"
        assert html =~ "The latest sequence run finished successfully."
        assert Session.sequence_run_state().status == :completed
        assert Session.pending_intent().pause.requested? == false
      end,
      240
    )

    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(fn ->
      html = render(view)
      assert html =~ "Pause Request"
      assert html =~ "Run Status"
      assert html =~ "Completed"
      assert html =~ "Auto"
      assert html =~ "Manual Operator"
    end)
  end

  test "sequence page reflects held state when workspace drift invalidates runtime trust" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()
    start_sequence_run!("pump_skid_commissioning")

    assert_eventually(fn ->
      run = Session.sequence_run_state()
      assert run.status in [:starting, :running]
      assert is_binary(run.current_step_label)
      assert String.starts_with?(run.current_step_label, "Hold ")
    end)

    drift_workspace!()

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Held"
        assert html =~ "Sequence run is held because runtime trust was invalidated"
        assert Session.sequence_run_state().status == :held
        assert Session.runtime_state().trust_state == :invalidated
      end,
      200
    )

    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(fn ->
      html = render(view)
      assert html =~ "Run Status"
      assert html =~ "Held"
      assert html =~ "Runtime Trust"
      assert html =~ "Invalidated"
      assert html =~ "Fault Source"
      assert html =~ "External Runtime"
      assert html =~ "Recoverability"
      assert html =~ "Operator Ack"
      assert html =~ "Fault Scope"
      assert html =~ "Runtime Wide"
      refute_sequence_runtime_controls(view)
    end)
  end

  test "sequence page reflects held state when the active runtime is stopped underneath Auto" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()
    start_sequence_run!("pump_skid_commissioning")

    assert_eventually(fn ->
      run = Session.sequence_run_state()
      assert run.status in [:starting, :running]
      assert is_binary(run.current_step_label)
      assert String.starts_with?(run.current_step_label, "Hold ")
    end)

    assert :ok = Session.set_desired_runtime(:stopped)

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Held"
        assert html =~ "Sequence run is held because runtime trust was invalidated"
        assert Session.sequence_run_state().status == :held
        assert Session.runtime_state().observed == :stopped
        assert Session.runtime_state().trust_state == :invalidated
      end,
      200
    )

    render_click(view, "select_view", %{"view" => "live"})

    assert_eventually(fn ->
      html = render(view)
      assert html =~ "Run Status"
      assert html =~ "Held"
      assert html =~ "Runtime"
      assert html =~ "Stopped"
      assert html =~ "Runtime Trust"
      assert html =~ "Invalidated"
      refute_sequence_runtime_controls(view)
    end)
  end

  test "sequence page reflects a resumed held run without exposing recovery controls" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()
    start_sequence_run!("pump_skid_commissioning")

    assert_eventually(fn ->
      run = Session.sequence_run_state()
      assert run.status in [:starting, :running]
      assert is_binary(run.current_step_label)
      assert String.starts_with?(run.current_step_label, "Hold ")
    end)

    original_source = Session.fetch_sequence("pump_skid_commissioning").source

    drift_workspace!(original_source)

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Held"
        assert Session.sequence_run_state().status == :held
        assert Session.runtime_state().trust_state == :invalidated
        refute_sequence_runtime_controls(view)
      end,
      200
    )

    restore_workspace!(original_source)

    assert_eventually(
      fn ->
        assert Session.runtime_state().observed == {:running, :live}
        assert Session.runtime_state().trust_state == :trusted
        assert Session.sequence_run_state().status == :held
      end,
      200
    )

    assert :ok = Session.resume_sequence_run()

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Completed"
        assert html =~ "The latest sequence run finished successfully."
        assert Session.sequence_run_state().status == :completed
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == :manual_operator
      end,
      240
    )
  end

  test "sequence page removes held resume when the active topology generation changes" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()

    original_generation =
      assert_eventually(fn ->
        assert Session.runtime_state().observed == {:running, :live}
        assert Session.runtime_state().trust_state == :trusted
        Session.runtime_state().topology_generation
      end)

    start_sequence_run!("pump_skid_commissioning")

    assert_eventually(fn ->
      run = Session.sequence_run_state()
      assert run.status in [:starting, :running]
      assert is_binary(run.current_step_label)
      assert String.starts_with?(run.current_step_label, "Hold ")
    end)

    original_source = Session.fetch_sequence("pump_skid_commissioning").source
    drift_workspace!(original_source)

    assert_eventually(fn ->
      assert Session.sequence_run_state().status == :held
      assert Session.runtime_state().invalidation_reasons == [:workspace_changed]
    end)

    restore_workspace!(original_source)

    assert_eventually(fn ->
      assert Session.runtime_state().trust_state == :trusted
      assert Session.runtime_state().topology_generation == original_generation
      assert Session.sequence_run_state().status == :held
    end)

    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(
      fn ->
        html = render(view)

        assert Session.runtime_state().observed == {:running, :live}
        assert Session.runtime_state().trust_state == :invalidated
        assert Session.runtime_state().invalidation_reasons == [:topology_generation_changed]
        refute Session.runtime_state().topology_generation == original_generation
        assert Session.sequence_run_state().status == :held
        refute_sequence_runtime_controls(view)
        assert html =~ "Held"
        assert html =~ ":topology_generation_changed"
      end,
      240
    )
  end

  test "sequence page reflects a faulted run without exposing recovery controls" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    inject_faulting_sequence!()
    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/pump_skid_commissioning")

    compile_sequence_from_page!(view)
    boot_live_runtime!()
    start_sequence_run!("pump_skid_commissioning")

    assert_eventually(
      fn ->
        html = render(view)

        assert html =~ "Sequence faulted"
        assert html =~ "fault injection: impossible valve feedback condition never arrived"
        assert Session.sequence_run_state().status == :faulted
        refute_sequence_runtime_controls(view)
      end,
      200
    )
  end

  test "source edits degrade honestly when the sequence leaves the supported visual subset" do
    draft = Session.create_sequence("pump_skid_manual")

    {:ok, view, _html} = live(build_conn(), "/studio/sequences/#{draft.id}")

    unsupported_source = """
    defmodule Ogol.Generated.Sequences.PumpSkidManual do
      use Ogol.Sequence

      sequence do
        name(:pump_skid_manual)
        topology(Ogol.Generated.Topologies.PackagingLine)

        if true do
          fail("unsupported")
        end
      end
    end
    """

    render_change(view, "change_source", %{"draft" => %{"source" => unsupported_source}})

    html = render(view)

    assert html =~ "Visual summary unavailable"
    assert html =~ "unsupported step constructs"
    assert has_element?(view, "[data-test='sequence-view-visual'][disabled]")
  end

  test "revision query is ignored and sequences still reflect the current workspace" do
    {:ok, _example, _revision_file, _report} =
      Examples.load_into_workspace(@example_id)

    draft = Session.create_sequence("revision_sequence")
    revision_model = Map.put(draft.model, :meaning, "Revision sequence from saved workspace")

    Session.save_sequence_source(
      draft.id,
      SequenceSource.to_source(revision_model),
      revision_model,
      :synced,
      []
    )

    {:ok, _revision} = Ogol.Session.Revisions.save_current(app_id: "sequences")

    current_workspace_model =
      Session.fetch_sequence("revision_sequence").model
      |> Map.put(:meaning, "Current workspace sequence")

    Session.save_sequence_source(
      draft.id,
      SequenceSource.to_source(current_workspace_model),
      current_workspace_model,
      :synced,
      []
    )

    {:ok, _view, html} =
      live(build_conn(), "/studio/sequences/revision_sequence?app_id=sequences&revision=r1")

    assert html =~ "Sequence Studio"
    assert html =~ "Current workspace sequence"
    refute html =~ "Revision sequence from saved workspace"
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

  defp drift_workspace! do
    Session.fetch_sequence("pump_skid_commissioning").source
    |> drift_workspace!()
  end

  defp drift_workspace!(original_source) when is_binary(original_source) do
    updated_source =
      String.replace(
        original_source,
        ~s|meaning("Commissioning cycle over a real EtherCAT loopback bench")|,
        ~s|meaning("Commissioning cycle with runtime drift injection")|,
        global: false
      )

    {:ok, updated_model} = SequenceSource.from_source(updated_source)

    Session.save_sequence_source(
      "pump_skid_commissioning",
      updated_source,
      updated_model,
      :synced,
      []
    )
  end

  defp restore_workspace!(original_source) when is_binary(original_source) do
    {:ok, original_model} = SequenceSource.from_source(original_source)

    Session.save_sequence_source(
      "pump_skid_commissioning",
      original_source,
      original_model,
      :synced,
      []
    )
  end

  defp inject_faulting_sequence! do
    draft = Session.fetch_sequence("pump_skid_commissioning")

    updated_source =
      draft.source
      |> String.replace(
        ~s|Ref.status(:supply_valve, :open_fb?)|,
        ~s|Expr.and_expr(Ref.status(:supply_valve, :open_fb?), Expr.not_expr(Ref.status(:supply_valve, :open_fb?)))|,
        global: false
      )
      |> String.replace(
        ~s|timeout: 2_000,\n        fail: "supply valve feedback did not go high"|,
        ~s|timeout: 50,\n        fail: "fault injection: impossible valve feedback condition never arrived"|,
        global: false
      )

    {:ok, updated_model} = SequenceSource.from_source(updated_source)

    Session.save_sequence_source(
      "pump_skid_commissioning",
      updated_source,
      updated_model,
      :synced,
      []
    )
  end

  defp compile_sequence_from_page!(view) do
    render_click(view, "request_transition", %{"transition" => "compile"})
  end

  defp boot_live_runtime! do
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
    end)
  end

  defp start_sequence_run!(sequence_id, opts \\ []) when is_binary(sequence_id) do
    policy = Keyword.get(opts, :policy, :once)

    assert :ok = Session.set_sequence_run_policy(policy)
    assert :ok = Session.set_control_mode(:auto)
    assert :ok = Session.start_sequence_run(sequence_id)
  end

  defp refute_sequence_runtime_controls(view) do
    refute has_element?(view, ~s(button[phx-value-transition="arm_auto"]))
    refute has_element?(view, ~s(button[phx-value-transition="manual"]))
    refute has_element?(view, ~s(button[phx-value-transition="run"]))
    refute has_element?(view, ~s(button[phx-value-transition="pause"]))
    refute has_element?(view, ~s(button[phx-value-transition="resume"]))
    refute has_element?(view, ~s(button[phx-value-transition="cancel"]))
    refute has_element?(view, ~s(button[phx-value-transition="acknowledge"]))
    refute has_element?(view, ~s(button[phx-value-transition="set_cycle_policy"]))
    refute has_element?(view, ~s(button[phx-value-transition="set_once_policy"]))
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
