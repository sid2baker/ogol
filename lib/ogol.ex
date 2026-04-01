defmodule Ogol do
  @moduledoc """
  Ogol root module.

  Machine interaction happens through generated functions on each machine module:

  - `MyMachine.skills/0` — list public skills
  - `MyMachine.start_cycle/2` — invoke a skill (generated per-skill)
  - `MyMachine.subscribe_signal/2` — subscribe to a specific signal
  - `MyMachine.subscribe_signals/1` — subscribe to all signals
  - `MyMachine.whereis/1` — look up a machine pid by id

  Runtime compilation, deployment, and machine interaction are available via `Ogol.Runtime`.
  Machine registration is handled by `Ogol.Machine.Registry`.
  """
end
