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
    _ = Ogol.Hardware.EtherCAT.RuntimeOwner.stop_all()
    _ = Ogol.Studio.Modules.reset()
    :ok = Ogol.Studio.WorkspaceStore.reset_loaded_revision()
    :ok = Ogol.Studio.WorkspaceStore.reset_drivers()
    :ok = Ogol.Studio.WorkspaceStore.reset_machines()
    :ok = Ogol.Studio.WorkspaceStore.reset_sequences()
    :ok = Ogol.Studio.WorkspaceStore.reset_topologies()
    :ok = Ogol.Studio.WorkspaceStore.reset_hmi_surfaces()
    :ok = Ogol.Studio.Revisions.reset()
    :ok = Ogol.Studio.WorkspaceStore.reset_hardware_config()
    :ok = Ogol.Runtime.Hardware.ReleaseStore.reset()
    :ok = Ogol.Runtime.Hardware.SupportSnapshotStore.reset()
    :ok = Ogol.HMI.Surface.RuntimeStore.reset()
    :ok = Ogol.HMI.Surface.DeploymentStore.reset()
    :ok = Ogol.Runtime.SnapshotStore.reset()
    :ok = Ogol.Runtime.EventLog.reset()

    on_exit(fn ->
      stop_active_topology()
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
end
