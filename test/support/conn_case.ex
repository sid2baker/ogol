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
    :ok = Ogol.HMI.HardwareConfigStore.reset()
    :ok = Ogol.HMI.SnapshotStore.reset()
    :ok = Ogol.HMI.EventLog.reset()
    :ok = Ogol.HMI.RuntimeIndex.reset()
    :ok
  end
end
