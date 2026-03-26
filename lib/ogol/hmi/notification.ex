defmodule Ogol.HMI.Notification do
  @moduledoc """
  Stable runtime notification envelope consumed by the HMI projection layer.
  """

  @type type ::
          :machine_started
          | :machine_stopped
          | :machine_down
          | :state_entered
          | :signal_emitted
          | :command_dispatched
          | :command_failed
          | :safety_violation
          | :child_state_entered
          | :child_signal_emitted
          | :child_down
          | :adapter_feedback
          | :adapter_status_changed
          | :topology_ready

  @type t :: %__MODULE__{
          type: type(),
          machine_id: atom() | nil,
          topology_id: atom() | nil,
          source: term(),
          occurred_at: integer(),
          payload: map(),
          meta: map()
        }

  @enforce_keys [:type, :occurred_at]
  defstruct [:type, :machine_id, :topology_id, :source, :occurred_at, payload: %{}, meta: %{}]

  @spec new(type(), keyword()) :: t()
  def new(type, opts \\ []) when is_atom(type) and is_list(opts) do
    %__MODULE__{
      type: type,
      machine_id: Keyword.get(opts, :machine_id),
      topology_id: Keyword.get(opts, :topology_id),
      source: Keyword.get(opts, :source),
      occurred_at: Keyword.get(opts, :occurred_at, System.system_time(:millisecond)),
      payload: Keyword.get(opts, :payload, %{}),
      meta: Keyword.get(opts, :meta, %{})
    }
  end
end
