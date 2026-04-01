defmodule Ogol.TestSupport.TestHardwareAdapter do
  @behaviour Ogol.Hardware.Adapter

  @impl true
  def dispatch(_machine, binding, command, data, meta) do
    send(binding, {:hardware_command, command, data, meta})
    :ok
  end

  @impl true
  def write_output(_machine, binding, output, value, meta) do
    send(binding, {:hardware_output, output, value, meta})
    :ok
  end
end
