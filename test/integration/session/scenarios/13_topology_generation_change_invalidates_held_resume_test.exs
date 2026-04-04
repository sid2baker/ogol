defmodule Ogol.Session.TopologyGenerationHeldResumeScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  test "topology generation change invalidates a previously resumable held run" do
    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()
    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.dispatch({:compile_artifact, :sequence, "pump_skid_commissioning"})
    assert :ok = Session.set_desired_runtime({:running, :live})

    original_generation =
      assert_eventually(fn ->
        runtime = Session.runtime_state()
        assert runtime.observed == {:running, :live}
        assert runtime.trust_state == :trusted
        assert is_binary(runtime.topology_generation)
        runtime.topology_generation
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

    original_source = Session.fetch_sequence("pump_skid_commissioning").source
    drift_workspace!(original_source)

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()
        runtime = Session.runtime_state()

        assert runtime.trust_state == :invalidated
        assert runtime.invalidation_reasons == [:workspace_changed]
        assert run.status == :held
        assert run.run_id == active_run_id
        assert run.run_generation == original_generation
        assert run.resumable? == true
        assert run.resume_blockers == []
      end,
      200
    )

    restore_workspace!(original_source)

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()
        runtime = Session.runtime_state()

        assert runtime.trust_state == :trusted
        assert runtime.topology_generation == original_generation
        assert run.status == :held
        assert run.run_generation == original_generation
        assert run.resumable? == true
        assert run.resume_blockers == []
      end,
      200
    )

    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()
        runtime = Session.runtime_state()

        assert runtime.observed == {:running, :live}
        assert runtime.trust_state == :invalidated
        assert runtime.invalidation_reasons == [:topology_generation_changed]
        assert is_binary(runtime.topology_generation)
        refute runtime.topology_generation == original_generation
        assert run.status == :held
        assert run.run_id == active_run_id
        assert run.run_generation == original_generation
        assert run.resumable? == false
        assert :topology_generation_changed in run.resume_blockers
        assert run.last_error == {:trust_invalidated, [:topology_generation_changed]}
      end,
      240
    )

    assert :error = Session.resume_sequence_run()

    assert :ok = Session.acknowledge_sequence_run()

    assert_eventually(
      fn ->
        assert Session.sequence_run_state().status == :idle
        assert Session.sequence_run_state().policy == :once
        assert Session.sequence_owner() == :manual_operator
        assert Session.control_mode() == :auto
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

  defp drift_workspace!(original_source) when is_binary(original_source) do
    updated_source =
      String.replace(
        original_source,
        ~s|meaning("Commissioning cycle over a real EtherCAT loopback bench")|,
        ~s|meaning("Commissioning cycle with generation invalidation")|,
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

  defp restore_workspace!(original_source) when is_binary(original_source) do
    assert {:ok, original_model} = SequenceSource.from_source(original_source)

    assert %Ogol.Session.Workspace.SourceDraft{id: "pump_skid_commissioning"} =
             Session.save_sequence_source(
               "pump_skid_commissioning",
               original_source,
               original_model,
               :synced,
               []
             )
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
