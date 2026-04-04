defmodule Ogol.Session.ExampleSequenceRunScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  test "checked-in example sequence runs through session-owned sequence truth" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware_config!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, "pump_skid_commissioning"})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
      assert Session.runtime_state().deployment_id
    end)

    assert :ok = Session.start_sequence_run("pump_skid_commissioning")
    assert Session.sequence_run_state().status == :running

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()
        runtime = Session.runtime_state()

        assert run.status == :completed
        assert run.sequence_id == "pump_skid_commissioning"
        assert run.sequence_module == Ogol.Generated.Sequences.PumpSkidCommissioning
        assert run.deployment_id == runtime.deployment_id
        assert run.topology_module == runtime.active_topology_module
        assert is_integer(run.started_at)
        assert is_integer(run.finished_at)
        assert run.last_error == nil
        assert runtime.observed == {:running, :live}
      end,
      120
    )
  end

  defp put_udp_hardware_config! do
    config = Session.fetch_hardware_config_model("ethercat")

    Session.put_hardware_config(%{
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
