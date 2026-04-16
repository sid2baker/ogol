defmodule Ogol.Session.HardwareOutputFailureScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Runtime.{EventLog, SnapshotStore}
  alias Ogol.Session
  alias Ogol.Session.Workspace.SourceDraft
  alias Ogol.Topology.Source, as: TopologySource
  alias Ogol.Topology.Wiring

  @hardware_id "faulty_output_hardware"
  @machine_id "return_valve"
  @machine_name :return_valve
  @topology_id "return_valve_fault_topology"
  @sequence_id "return_valve_hardware_fault"

  test "hardware output failure faults the run without restarting the machine" do
    Session.replace_machines([machine_draft()])
    Session.replace_topologies([topology_draft()])
    Session.replace_sequences([sequence_draft()])
    Session.replace_hardware([hardware_draft()])

    assert :ok = Session.dispatch({:compile_artifact, :sequence, @sequence_id})
    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      runtime = Session.runtime_state()

      assert runtime.observed == {:running, :live}
      assert runtime.trust_state == :trusted
      assert runtime.active_topology_module == Ogol.Generated.Topologies.ReturnValveFaultTopology
      assert is_binary(runtime.deployment_id)
    end)

    assert :ok = Session.set_control_mode(:auto)
    assert :ok = Session.start_sequence_run(@sequence_id)

    assert_eventually(
      fn ->
        run = Session.sequence_run_state()

        assert run.status == :faulted
        assert run.sequence_id == @sequence_id
        assert is_binary(run.run_id)
        assert is_binary(run.last_error)
        assert run.last_error =~ "Open return valve failed"
        assert run.last_error =~ "hardware_output_failed"
        assert run.last_error =~ "slave_down"
        refute run.last_error =~ "target_runtime_failure"
        assert run.fault_source == :external_runtime
        assert run.fault_recoverability == :abort_required
        assert run.fault_scope == :runtime_wide
        assert is_integer(run.finished_at)
        assert Session.sequence_owner() == :manual_operator
        assert Session.control_mode() == :auto
      end,
      200
    )

    assert_eventually(
      fn ->
        snapshot = SnapshotStore.get_machine(@machine_name)
        assert snapshot
        assert snapshot.current_state == :closed
        assert snapshot.health == :healthy
        assert snapshot.restart_count == 0
        assert snapshot.faults == []
        assert snapshot.outputs[:open_cmd?] == false
        refute machine_down_event?({:hardware_output_failed, :slave_down})
      end,
      200
    )

    runtime = Session.runtime_state()
    assert runtime.observed == {:running, :live}
    assert runtime.trust_state == :trusted
  end

  defp machine_draft do
    %SourceDraft{
      id: @machine_id,
      source: machine_source(),
      model: nil,
      sync_state: :unsupported,
      sync_diagnostics: []
    }
  end

  defp topology_draft do
    %SourceDraft{
      id: @topology_id,
      source: topology_source(),
      model: nil,
      sync_state: :unsupported,
      sync_diagnostics: []
    }
  end

  defp sequence_draft do
    %SourceDraft{
      id: @sequence_id,
      source: sequence_source(),
      model: nil,
      sync_state: :unsupported,
      sync_diagnostics: []
    }
  end

  defp hardware_draft do
    %SourceDraft{
      id: @hardware_id,
      source: hardware_source(),
      model: nil,
      sync_state: :unsupported,
      sync_diagnostics: []
    }
  end

  defp machine_source do
    """
    defmodule Ogol.Generated.Machines.ReturnValve do
      use Ogol.Machine

      machine do
        name(:return_valve)
        meaning("Return valve used to reproduce hardware output failures")
      end

      boundary do
        request(:open)
        output(:open_cmd?, :boolean, default: false, public?: true)
      end

      states do
        state :closed do
          initial?(true)
          status("Closed")
          meaning("Valve is closed")
        end

        state :open do
          status("Open")
          meaning("Valve is open")
          set_output(:open_cmd?, true)
        end
      end

      transitions do
        transition :closed, :open do
          on({:request, :open})
          reply(:ok)
        end

        transition :open, :open do
          on({:request, :open})
          reply(:ok)
        end
      end
    end
    """
  end

  defp topology_source do
    TopologySource.to_source(%{
      module_name: "Ogol.Generated.Topologies.ReturnValveFaultTopology",
      strategy: "one_for_one",
      meaning: "Topology used to reproduce return valve output failures",
      machines: [
        %{
          name: @machine_id,
          module_name: "Ogol.Generated.Machines.ReturnValve",
          restart: "permanent",
          meaning: "Valve wired to a hardware module that fails output writes",
          wiring: %Wiring{
            outputs: %{open_cmd?: {:faulty_outputs, :open_cmd}}
          }
        }
      ]
    })
  end

  defp sequence_source do
    """
    defmodule Ogol.Generated.Sequences.ReturnValveHardwareFault do
      use Ogol.Sequence

      sequence do
        name(:return_valve_hardware_fault)
        topology(Ogol.Generated.Topologies.ReturnValveFaultTopology)
        meaning("Reproduce a hardware output failure during a session-owned run")

        proc :startup do
          do_skill(:return_valve, :open, meaning: "Open return valve")
        end

        run(:startup)
      end
    end
    """
  end

  defp hardware_source do
    """
    defmodule Ogol.Generated.Hardware.FaultyOutputHardware do
      use Ogol.Hardware

      alias Ogol.Topology.Wiring

      def hardware do
        %{Ogol.Hardware.EtherCAT.default() | id: "#{@hardware_id}", label: "Faulty Output Hardware"}
      end

      def id, do: "#{@hardware_id}"
      def label, do: "Faulty Output Hardware"

      def child_specs(_opts \\\\ []), do: {:ok, []}
      def init(init_arg), do: {:ok, init_arg}

      def bind(%Wiring{} = wiring), do: {:ok, wiring}

      def normalize_message(_binding, _message), do: nil
      def attach(_machine, _server, _binding), do: :ok
      def dispatch_command(_machine, _binding, _command, _data, _meta), do: :ok

      def write_output(_machine, _binding, :open_cmd?, true, _meta), do: {:error, :slave_down}
      def write_output(_machine, _binding, _output, _value, _meta), do: :ok
    end
    """
  end

  defp machine_down_event?(reason) do
    EventLog.recent()
    |> Enum.any?(fn
      %Ogol.Runtime.Notification{
        type: :machine_down,
        machine_id: @machine_name,
        payload: %{reason: ^reason}
      } ->
        true

      _other ->
        false
    end)
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
