defmodule Ogol.Session.AutoModeOwnershipScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  test "auto mode gates sequence admission and releases owner after completion" do
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

    assert :error = Session.start_sequence_run("pump_skid_commissioning")

    assert :ok = Session.set_control_mode(:auto)
    assert Session.control_mode() == :auto
    assert Session.sequence_owner() == :manual_operator

    assert :ok = Session.start_sequence_run("pump_skid_commissioning")
    assert Session.sequence_run_state().status in [:starting, :running]
    assert match?({:sequence_run, _}, Session.sequence_owner())
    assert :error = Session.set_control_mode(:manual)

    assert_eventually(
      fn ->
        assert Session.sequence_run_state().status == :completed
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == :manual_operator
      end,
      200
    )

    assert :ok = Session.set_control_mode(:manual)
    assert Session.control_mode() == :manual
    assert Session.sequence_owner() == :manual_operator
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
