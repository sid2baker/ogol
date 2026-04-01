defmodule Ogol.HMI.Surface.DeviceProfile do
  @moduledoc false

  @type t :: %__MODULE__{
          id: atom(),
          width: pos_integer(),
          height: pos_integer(),
          touch: boolean(),
          orientation: :landscape | :portrait,
          density_class: atom() | nil,
          panel_class: atom() | nil,
          interaction_mode: atom() | nil,
          kiosk: boolean() | nil,
          distance_class: atom() | nil
        }

  defstruct [
    :id,
    :width,
    :height,
    :touch,
    :orientation,
    :density_class,
    :panel_class,
    :interaction_mode,
    :kiosk,
    :distance_class
  ]
end
