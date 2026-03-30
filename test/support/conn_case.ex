defmodule Ogol.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint Ogol.HMIWeb.Endpoint
    end
  end

  setup _tags do
    stop_active_topology()
    _ = Ogol.HMI.EthercatRuntimeOwner.stop_all()
    :ok = Ogol.Studio.ModuleStatusStore.reset()
    :ok = Ogol.Studio.DriverDraftStore.reset()
    :ok = Ogol.Studio.MachineDraftStore.reset()
    :ok = Ogol.Studio.SequenceDraftStore.reset()
    :ok = Ogol.Studio.TopologyDraftStore.reset()
    :ok = Ogol.Studio.RevisionStore.reset()
    :ok = Ogol.HMI.HardwareConfigStore.reset()
    :ok = Ogol.HMI.HardwareReleaseStore.reset()
    :ok = Ogol.HMI.HardwareSupportSnapshotStore.reset()
    :ok = Ogol.HMI.SurfaceDraftStore.reset()
    :ok = Ogol.HMI.SurfaceDeploymentStore.reset()
    :ok = Ogol.HMI.SnapshotStore.reset()
    :ok = Ogol.HMI.EventLog.reset()
    :ok = Ogol.HMI.RuntimeIndex.reset()
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
