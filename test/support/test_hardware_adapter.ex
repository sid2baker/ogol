defmodule Ogol.TestSupport.TestHardwareAdapter do
  @behaviour Ogol.HardwareAdapter

  @impl true
  def dispatch(_machine, hardware_ref, command, data, meta) do
    send(hardware_ref, {:hardware_command, command, data, meta})
    :ok
  end

  @impl true
  def write_output(_machine, hardware_ref, output, value, meta) do
    send(hardware_ref, {:hardware_output, output, value, meta})
    :ok
  end
end
