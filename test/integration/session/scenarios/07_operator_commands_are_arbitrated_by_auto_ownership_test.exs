defmodule Ogol.Session.AutoOwnershipCommandArbitrationScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  test "operator commands are denied while Auto owns orchestration and re-enabled in Manual" do
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
    assert {:error, :auto_mode_armed} = Session.invoke_machine(:alarm_stack, :show_fault)

    assert :ok = Session.start_sequence_run("pump_skid_commissioning")

    active_run_id =
      assert_eventually(fn ->
        assert Session.sequence_run_state().status in [:starting, :running]
        assert {:sequence_run, run_id} = Session.sequence_owner()
        assert is_binary(run_id)
        run_id
      end)

    assert {:error, {:owned_by_sequence_run, ^active_run_id}} =
             Session.invoke_machine(:alarm_stack, :show_fault)

    assert_eventually(
      fn ->
        assert Session.sequence_run_state().status == :completed
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == :manual_operator
      end,
      200
    )

    assert {:error, :auto_mode_armed} = Session.invoke_machine(:alarm_stack, :show_fault)

    assert :ok = Session.set_control_mode(:manual)
    assert {:ok, :ok} = Session.invoke_machine(:alarm_stack, :show_fault)
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
