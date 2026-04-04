defmodule Ogol.TestSupport.TestHardwareAdapter do
  def dispatch_command(_machine, binding, command, data, meta) do
    send(binding, {:hardware_command, command, data, meta})
    :ok
  end

  def write_output(_machine, binding, output, value, meta) do
    send(binding, {:hardware_output, output, value, meta})
    :ok
  end
end
