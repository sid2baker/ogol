defmodule Ogol.Session.CyclePolicyExampleScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  test "cycle policy keeps the example sequence running across cycle boundaries until aborted" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, "pump_skid_commissioning"})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      runtime = Session.runtime_state()
      assert runtime.observed == {:running, :live}
      assert runtime.deployment_id
    end)

    assert :ok = Session.set_sequence_run_policy(:cycle)
    assert Session.sequence_run_state().policy == :cycle

    assert :ok = Session.set_control_mode(:auto)
    assert :ok = Session.start_sequence_run("pump_skid_commissioning")

    active_run_id =
      assert_eventually(
        fn ->
          run = Session.sequence_run_state()

          assert run.status in [:starting, :running]
          assert run.policy == :cycle
          assert is_binary(run.run_id)
          run.run_id
        end,
        120
      )

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()

        assert run.status == :running
        assert run.run_id == active_run_id
        assert run.policy == :cycle
        assert run.cycle_count >= 1
        assert is_binary(run.resume_from_boundary)
        refute run.current_step_label == nil
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == {:sequence_run, active_run_id}
      end,
      320
    )

    assert :ok = Session.cancel_sequence_run()

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()

        assert run.status == :aborted
        assert run.policy == :cycle
        assert run.cycle_count >= 1
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == :manual_operator
      end,
      200
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
