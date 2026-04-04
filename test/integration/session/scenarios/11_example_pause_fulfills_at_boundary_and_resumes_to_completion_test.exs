defmodule Ogol.Session.ExamplePauseResumeScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  test "checked-in example pause fulfills at a boundary and resumes to completion" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, "pump_skid_commissioning"})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
      assert Session.runtime_state().deployment_id
    end)

    assert :ok = Session.set_control_mode(:auto)
    assert :ok = Session.start_sequence_run("pump_skid_commissioning")

    active_run_id =
      assert_eventually(fn ->
        run = Session.sequence_run_state()

        assert run.status in [:starting, :running]
        assert is_binary(run.run_id)
        assert is_binary(run.current_step_label)
        assert String.starts_with?(run.current_step_label, "Hold ")
        run.run_id
      end)

    assert :ok = Session.pause_sequence_run()

    assert_eventually(fn ->
      pause_intent = Session.pending_intent().pause
      assert pause_intent.requested? == true
      assert pause_intent.admitted? == true
    end)

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()
        runtime = Session.runtime_state()
        pause_intent = Session.pending_intent().pause

        assert run.status == :paused
        assert run.run_id == active_run_id
        assert run.resumable? == true
        assert is_binary(run.resume_from_boundary)
        assert run.resume_blockers == []
        assert runtime.observed == {:running, :live}
        assert runtime.trust_state == :trusted
        assert pause_intent.fulfilled? == true
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == {:sequence_run, active_run_id}
      end,
      200
    )

    assert :ok = Session.resume_sequence_run()

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()
        pause_intent = Session.pending_intent().pause

        assert run.status == :completed
        assert run.sequence_id == "pump_skid_commissioning"
        assert pause_intent.requested? == false
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == :manual_operator
      end,
      300
    )
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

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end
end
