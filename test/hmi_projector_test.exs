defmodule Ogol.HMI.ProjectorTest do
  use ExUnit.Case, async: false

  alias Ogol.HMI.{
    EventLog,
    HardwareSnapshot,
    MachineSnapshot,
    Notification,
    SnapshotStore,
    TopologySnapshot
  }

  alias Ogol.Examples.SimpleHmiDemo

  setup do
    :ok = SnapshotStore.reset()
    :ok = EventLog.reset()
    :ok
  end

  test "projects machine, topology, and hardware notifications into snapshots" do
    Ogol.HMI.Projector.project(
      Notification.new(:machine_started,
        machine_id: :press,
        payload: %{module: Ogol.TestSupport.SampleMachine}
      )
    )

    Ogol.HMI.Projector.project(
      Notification.new(:state_entered,
        machine_id: :press,
        payload: %{module: Ogol.TestSupport.SampleMachine, state: :running}
      )
    )

    Ogol.HMI.Projector.project(
      Notification.new(:signal_emitted,
        machine_id: :press,
        payload: %{name: :started}
      )
    )

    Ogol.HMI.Projector.project(
      Notification.new(:topology_ready,
        machine_id: :press,
        topology_id: :press,
        payload: %{root_machine_id: :press}
      )
    )

    Ogol.HMI.Projector.project(
      Notification.new(:adapter_feedback,
        machine_id: :press,
        payload: %{signal: :closed_fb, value: true},
        meta: %{bus: :ethercat, endpoint_id: :clamp_io}
      )
    )

    Ogol.HMI.Projector.project(
      Notification.new(:dependency_status_updated,
        machine_id: :press,
        topology_id: :press,
        payload: %{dependency: :clamp, item: :closed?, value: true}
      )
    )

    assert_eventually(fn ->
      assert %MachineSnapshot{current_state: :running, last_signal: :started, health: :running} =
               SnapshotStore.get_machine(:press)

      assert %TopologySnapshot{topology_id: :press, root_machine_id: :press} =
               SnapshotStore.get_topology(:press)

      assert [%{name: "clamp", status: %{closed?: true}}] =
               SnapshotStore.get_topology(:press).dependencies

      assert %HardwareSnapshot{
               bus: :ethercat,
               endpoint_id: :clamp_io,
               observed_signals: %{closed_fb: true}
             } = SnapshotStore.get_hardware(:ethercat, :clamp_io)
    end)
  end

  test "machine snapshots reflect live facts, fields, outputs, and crash state" do
    {:ok, pid} = SimpleHmiDemo.boot!()
    Process.unlink(pid)

    on_exit(fn ->
      if Process.alive?(pid) do
        Process.exit(pid, :shutdown)
      end
    end)

    assert_eventually(fn ->
      assert %MachineSnapshot{
               current_state: :idle,
               health: :waiting,
               facts: %{enabled?: true},
               fields: %{part_count: 0},
               outputs: %{running?: false}
             } = SnapshotStore.get_machine(:simple_hmi_line)
    end)

    assert {:ok, :ok} = Ogol.Runtime.Delivery.invoke(pid, :start)
    assert {:ok, :accepted} = Ogol.Runtime.Delivery.invoke(pid, :part_seen)

    assert_eventually(fn ->
      assert %MachineSnapshot{
               current_state: :running,
               health: :running,
               last_signal: :part_counted,
               fields: %{part_count: 1},
               outputs: %{running?: true}
             } = SnapshotStore.get_machine(:simple_hmi_line)
    end)

    Process.exit(pid, :boom)

    assert_eventually(fn ->
      assert %MachineSnapshot{health: :crashed, connected?: false} =
               SnapshotStore.get_machine(:simple_hmi_line)
    end)
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError] ->
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
  end
end
