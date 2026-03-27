defmodule Ogol.HMI.HardwareConfig do
  @moduledoc false

  @enforce_keys [:id, :protocol, :label, :spec]
  defstruct [:id, :protocol, :label, :spec, :inserted_at, :updated_at, meta: %{}]
end
