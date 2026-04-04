defmodule Ogol.Session.FaultedRunAcknowledgmentScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  test "faulted sequence runs can be acknowledged back to idle while Auto stays armed" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    inject_faulting_sequence!()
    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, "pump_skid_commissioning"})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      runtime = Session.runtime_state()
      assert runtime.observed == {:running, :live}
      assert runtime.trust_state == :trusted
    end)

    assert :ok = Session.set_control_mode(:auto)
    assert :ok = Session.start_sequence_run("pump_skid_commissioning")

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()

        assert run.status == :faulted
        assert run.last_error == "fault injection: closed signal never arrived"
        assert run.fault_source == :sequence_logic
        assert run.fault_recoverability == :abort_required
        assert run.fault_scope == :step_local
        assert Session.control_mode() == :auto
        assert Session.sequence_owner() == :manual_operator
      end,
      200
    )

    assert :ok = Session.acknowledge_sequence_run()

    assert_eventually(fn ->
      run = Session.sequence_run_state()
      runtime = Session.runtime_state()

      assert run.status == :idle
      assert run.policy == :once
      assert run.cycle_count == 0
      assert runtime.observed == {:running, :live}
      assert runtime.trust_state == :trusted
      assert Session.control_mode() == :auto
      assert Session.sequence_owner() == :manual_operator
    end)
  end

  defp inject_faulting_sequence! do
    draft = Session.fetch_sequence("pump_skid_commissioning")

    updated_source =
      draft.source
      |> String.replace(
        ~s|Ref.signal(:supply_valve, :opened)|,
        ~s|Ref.signal(:supply_valve, :closed)|,
        global: false
      )
      |> String.replace(
        ~s|timeout: 2_000,\n        fail: "supply valve feedback did not go high"|,
        ~s|timeout: 50,\n        fail: "fault injection: closed signal never arrived"|,
        global: false
      )

    assert {:ok, updated_model} = SequenceSource.from_source(updated_source)

    assert %Ogol.Session.Workspace.SourceDraft{id: "pump_skid_commissioning"} =
             Session.save_sequence_source(
               "pump_skid_commissioning",
               updated_source,
               updated_model,
               :synced,
               []
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
