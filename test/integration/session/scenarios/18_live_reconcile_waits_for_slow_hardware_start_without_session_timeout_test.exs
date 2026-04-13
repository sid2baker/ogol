defmodule Ogol.TestSupport.RuntimeStartGate do
  @moduledoc false

  @owner_key {__MODULE__, :owner}

  def register_owner(pid) when is_pid(pid) do
    :persistent_term.put(@owner_key, pid)
    :ok
  end

  def clear_owner do
    :persistent_term.erase(@owner_key)
    :ok
  end

  def await_release(runtime_session_pid) when is_pid(runtime_session_pid) do
    case :persistent_term.get(@owner_key, nil) do
      owner when is_pid(owner) ->
        send(owner, {:slow_hardware_session_waiting, runtime_session_pid})

      _other ->
        :ok
    end

    receive do
      :release_runtime_start -> :ok
    after
      20_000 -> exit(:runtime_start_gate_timeout)
    end
  end
end

defmodule Ogol.Session.SlowHardwareStartScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Session
  alias Ogol.Session.Workspace.SourceDraft
  alias Ogol.Topology.Source, as: TopologySource
  alias Ogol.Topology.Wiring

  @hardware_id "slow_start_hardware"
  @machine_id "slow_start_machine"
  @topology_id "slow_start_topology"
  @old_dispatch_budget_ms 15_000
  @cross_timeout_ms 15_100

  test "live reconcile waits for slow hardware startup without timing out the session call" do
    on_exit(fn -> Ogol.TestSupport.RuntimeStartGate.clear_owner() end)

    :ok = Ogol.TestSupport.RuntimeStartGate.register_owner(self())

    Session.replace_machines([machine_draft()])
    Session.replace_topologies([topology_draft()])
    Session.replace_hardware([hardware_draft()])

    supervisor = start_supervised!(Task.Supervisor)
    start_started_ms = System.monotonic_time(:millisecond)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        Session.set_desired_runtime({:running, :live})
      end)

    assert_receive {:slow_hardware_session_waiting, runtime_session_pid}, 2_000
    assert is_pid(runtime_session_pid)

    Process.sleep(@cross_timeout_ms)

    assert Process.alive?(task.pid)
    assert Task.yield(task, 0) == nil

    start_finished_ms = System.monotonic_time(:millisecond)
    send(runtime_session_pid, :release_runtime_start)

    assert {:ok, :ok} = Task.yield(task, 5_000)

    runtime = Session.runtime_state()

    assert runtime.desired == {:running, :live}
    assert runtime.observed == {:running, :live}
    assert runtime.status == :running
    assert runtime.last_error == nil
    assert runtime.active_topology_module == Ogol.Generated.Topologies.SlowStartTopology
    assert start_finished_ms - start_started_ms >= @old_dispatch_budget_ms

    assert :ok = Session.set_desired_runtime(:stopped)
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

  defp hardware_draft do
    %SourceDraft{
      id: @hardware_id,
      source: hardware_source(),
      model: nil,
      sync_state: :unsupported,
      sync_diagnostics: []
    }
  end

  defp topology_source do
    TopologySource.to_source(%{
      module_name: "Ogol.Generated.Topologies.SlowStartTopology",
      strategy: "one_for_one",
      meaning: "Topology with intentionally slow hardware startup",
      machines: [
        %{
          name: @machine_id,
          module_name: "Ogol.Generated.Machines.SlowStartMachine",
          restart: "permanent",
          meaning: "Machine used to force topology hardware startup",
          wiring: %Wiring{
            outputs: %{ready_lamp: {:slow_start_slave, :lamp}},
            facts: %{},
            commands: %{},
            event_name: nil
          }
        }
      ]
    })
  end

  defp machine_source do
    """
    defmodule Ogol.Generated.Machines.SlowStartMachine do
      use Ogol.Machine

      machine do
        name(:slow_start_machine)
        meaning("Machine used to pin runtime-start timeout behavior")
      end

      boundary do
        output(:ready_lamp, :boolean, default: false, public?: true)
      end

      states do
        state :idle do
          initial?(true)
          status("Idle")
          set_output(:ready_lamp, false)
        end
      end
    end
    """
  end

  defp hardware_source do
    """
    defmodule Ogol.Generated.Hardware.SlowStartHardware do
      use Ogol.Hardware

      alias Ogol.Topology.Wiring

      def hardware do
        %{Ogol.Hardware.EtherCAT.default() | id: "#{@hardware_id}", label: "Slow Start Hardware"}
      end

      def id, do: "#{@hardware_id}"
      def label, do: "Slow Start Hardware"

      def child_specs(_opts \\\\ []) do
        {:ok,
         [
           Supervisor.child_spec(
             %{id: {:slow_start_hardware_session, id()}, start: {__MODULE__, :start_session_link, []}},
             id: {:slow_start_hardware_session, id()}
           )
         ]}
      end

      def start_session_link do
        GenServer.start_link(__MODULE__, :runtime_session)
      end

      def init(:runtime_session) do
        Ogol.TestSupport.RuntimeStartGate.await_release(self())
        {:ok, %{}}
      end

      def bind(%Wiring{} = wiring), do: {:ok, wiring}

      def normalize_message(_binding, _message), do: nil
      def attach(_machine, _server, _binding), do: :ok
      def dispatch_command(_machine, _binding, _command, _data, _meta), do: :ok
      def write_output(_machine, _binding, _output, _value, _meta), do: :ok
    end
    """
  end
end
