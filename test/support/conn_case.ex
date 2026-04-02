defmodule Ogol.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint OgolWeb.Endpoint
    end
  end

  setup _tags do
    stop_active_topology()
    stop_registered_machines()
    _ = Ogol.Hardware.EtherCAT.RuntimeOwner.stop_all()
    _ = Ogol.Runtime.reset()
    :ok = Ogol.Session.reset_loaded_revision()
    :ok = Ogol.Session.reset_machines()
    :ok = Ogol.Session.reset_sequences()
    :ok = Ogol.Session.reset_topologies()
    :ok = Ogol.Session.reset_hmi_surfaces()
    :ok = Ogol.Session.Revisions.reset()
    :ok = Ogol.Session.reset_hardware_configs()
    :ok = Ogol.Runtime.Hardware.ReleaseStore.reset()
    :ok = Ogol.Runtime.Hardware.SupportSnapshotStore.reset()
    :ok = Ogol.HMI.Surface.RuntimeStore.reset()
    :ok = Ogol.HMI.Surface.DeploymentStore.reset()
    :ok = Ogol.Runtime.SnapshotStore.reset()
    :ok = Ogol.Runtime.EventLog.reset()
    {:ok, _example, _revision_file, _report} = Ogol.Session.load_example("packaging_line")
    :ok = Ogol.Session.reset_loaded_revision()

    on_exit(fn ->
      stop_active_topology()
      stop_registered_machines()
      _ = Ogol.Hardware.EtherCAT.RuntimeOwner.stop_all()
    end)

    :ok
  end

  defp stop_active_topology do
    case Ogol.Topology.Registry.active_topology() do
      %{pid: pid} when is_pid(pid) ->
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _reason -> :ok
        end

        await_topology_clear()

      _ ->
        :ok
    end
  end

  defp await_topology_clear(attempts \\ 50)

  defp await_topology_clear(0), do: :ok

  defp await_topology_clear(attempts) do
    case Ogol.Topology.Registry.active_topology() do
      nil ->
        :ok

      _active ->
        Process.sleep(10)
        await_topology_clear(attempts - 1)
    end
  end

  defp stop_registered_machines do
    Ogol.Machine.Registry.instances()
    |> Enum.each(fn {_machine_id, pid} ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :shutdown)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    await_machine_clear()
  end

  defp await_machine_clear(attempts \\ 50)

  defp await_machine_clear(0), do: :ok

  defp await_machine_clear(attempts) do
    case Ogol.Machine.Registry.instances() do
      [] ->
        :ok

      _instances ->
        Process.sleep(10)
        await_machine_clear(attempts - 1)
    end
  end
end
