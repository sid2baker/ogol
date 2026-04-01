defmodule Ogol.Runtime.HardwareSnapshot do
  @moduledoc false

  @enforce_keys [:bus, :endpoint_id, :connected?]
  defstruct [
    :bus,
    :endpoint_id,
    :connected?,
    :last_feedback_at,
    observed_signals: %{},
    driven_outputs: %{},
    status: %{},
    faults: [],
    meta: %{}
  ]
end
