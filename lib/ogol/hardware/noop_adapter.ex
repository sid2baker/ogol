defmodule Ogol.Hardware.NoopAdapter do
  @moduledoc false

  @behaviour Ogol.Hardware.Adapter

  @impl true
  def dispatch(_machine, _binding, _command, _data, _meta), do: :ok

  @impl true
  def write_output(_machine, _binding, _output, _value, _meta), do: :ok
end
