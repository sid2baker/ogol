defmodule Ogol.Runtime.MachineSnapshot do
  @moduledoc false

  @type health ::
          :healthy
          | :running
          | :waiting
          | :stopped
          | :faulted
          | :crashed
          | :recovering
          | :stale
          | :disconnected

  @type t :: %__MODULE__{
          machine_id: atom(),
          module: module() | nil,
          current_state: atom() | nil,
          health: health(),
          last_signal: atom() | nil,
          last_transition_at: integer() | nil,
          restart_count: non_neg_integer(),
          connected?: boolean(),
          facts: map(),
          fields: map(),
          outputs: map(),
          alarms: [map()],
          faults: [map()],
          dependencies: [map()],
          adapter_status: map(),
          meta: map()
        }

  @enforce_keys [:machine_id, :health]
  defstruct [
    :machine_id,
    :module,
    :current_state,
    :health,
    :last_signal,
    :last_transition_at,
    restart_count: 0,
    connected?: false,
    facts: %{},
    fields: %{},
    outputs: %{},
    alarms: [],
    faults: [],
    dependencies: [],
    adapter_status: %{},
    meta: %{}
  ]
end
