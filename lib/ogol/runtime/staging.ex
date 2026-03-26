defmodule Ogol.Runtime.Staging do
  @moduledoc false

  defstruct [
    :data,
    :request_from,
    :state_override,
    :stop_reason,
    reply_count: 0,
    boundary_effects: [],
    otp_actions: []
  ]
end
