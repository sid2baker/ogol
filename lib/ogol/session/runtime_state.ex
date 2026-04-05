defmodule Ogol.Session.RuntimeState do
  @moduledoc false

  @type realization :: :stopped | {:running, :simulation} | {:running, :live}
  @type status :: :idle | :reconciling | :running | :failed
  @type trust_state :: :trusted | :invalidated

  @type t :: %__MODULE__{
          desired: realization(),
          observed: realization(),
          status: status(),
          trust_state: trust_state(),
          invalidation_reasons: [term()],
          topology_generation: String.t() | nil,
          deployment_id: String.t() | nil,
          active_topology_module: module() | nil,
          active_adapters: [atom()],
          realized_workspace_hash: String.t() | nil,
          last_error: term() | nil
        }

  defstruct desired: :stopped,
            observed: :stopped,
            status: :idle,
            trust_state: :trusted,
            invalidation_reasons: [],
            topology_generation: nil,
            deployment_id: nil,
            active_topology_module: nil,
            active_adapters: [],
            realized_workspace_hash: nil,
            last_error: nil
end
