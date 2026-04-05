defmodule Ogol.Session.ProcedureSelectionAndTakeoverScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"
  @sequence_id "pump_skid_commissioning"

  test "selected procedure and takeover intent are stored as session truth" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    assert :ok = Session.select_procedure(@sequence_id)
    assert Session.selected_procedure_id() == @sequence_id

    pre_runtime_entry =
      Session.operator_procedure_catalog()
      |> Enum.find(&(&1.sequence_id == @sequence_id))

    assert pre_runtime_entry.selected? == true
    assert pre_runtime_entry.eligible? == false
    assert pre_runtime_entry.eligibility_reason_code == :runtime_not_running

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, @sequence_id})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      assert Session.runtime_state().observed == {:running, :live}
      assert Session.runtime_state().deployment_id
    end)

    assert :ok = Session.set_control_mode(:auto)
    assert :ok = Session.start_sequence_run(@sequence_id)

    active_run_id =
      assert_eventually(fn ->
        run = Session.sequence_run_state()

        assert run.status in [:starting, :running]
        assert is_binary(run.run_id)
        run.run_id
      end)

    assert :error = Session.select_procedure(@sequence_id)

    assert :ok = Session.request_manual_takeover()

    assert_eventually(
      fn ->
        takeover_intent = Session.pending_intent().takeover
        run = Session.sequence_run_state()

        assert takeover_intent.requested? == false
        assert Session.control_mode() == :manual
        assert Session.sequence_owner() == :manual_operator
        assert run.status == :aborted
        assert run.run_id == active_run_id
      end,
      160
    )

    catalog_entry =
      Session.operator_procedure_catalog()
      |> Enum.find(&(&1.sequence_id == @sequence_id))

    assert catalog_entry.selected? == true
    assert catalog_entry.active? == false
    assert catalog_entry.startable? == false
    assert catalog_entry.blocked_reason_code == :terminal_result_pending

    assert :error = Session.request_manual_takeover()
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
