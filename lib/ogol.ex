defmodule Ogol do
  @moduledoc """
  Public runtime helpers for generated Ogol machine modules.

  The authored DSL is defined in `Ogol.Machine`. Generated machine modules are
  intended to expose their own `start_link/1`, while `Ogol` provides the common
  request/event delivery surface used by callers and tests.
  """

  @type event_payload :: map()
  @type event_meta :: map()

  @spec request(GenServer.server(), atom(), event_payload(), event_meta(), timeout()) :: term()
  def request(server, name, data \\ %{}, meta \\ %{}, timeout \\ 5_000)
      when is_atom(name) and is_map(data) and is_map(meta) do
    :gen_statem.call(server, {:request, name, data, meta}, timeout)
  end

  @spec event(GenServer.server(), atom(), event_payload(), event_meta()) :: :ok
  def event(server, name, data \\ %{}, meta \\ %{})
      when is_atom(name) and is_map(data) and is_map(meta) do
    :gen_statem.cast(server, {:event, name, data, meta})
  end

  @spec hardware_event(GenServer.server(), atom(), event_payload(), event_meta()) :: :ok
  def hardware_event(server, name, data \\ %{}, meta \\ %{})
      when is_atom(name) and is_map(data) and is_map(meta) do
    send(server, {:ogol_hardware_event, name, data, meta})
    :ok
  end
end
