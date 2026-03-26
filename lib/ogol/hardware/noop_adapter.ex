defmodule Ogol.Hardware.NoopAdapter do
  @moduledoc false

  @behaviour Ogol.HardwareAdapter

  @impl true
  def dispatch(_machine, _hardware_ref, _command, _data, _meta), do: :ok

  @impl true
  def write_output(_machine, _hardware_ref, _output, _value, _meta), do: :ok
end
