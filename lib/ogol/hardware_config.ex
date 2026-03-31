defmodule Ogol.HardwareConfig do
  @moduledoc false

  alias Ogol.HardwareConfig.EtherCAT

  @enforce_keys [:id, :protocol, :label, :spec]
  defstruct [:id, :protocol, :label, :spec, :inserted_at, :updated_at, meta: %{}]

  @type spec_t :: EtherCAT.t()

  @type t :: %__MODULE__{
          id: String.t(),
          protocol: atom(),
          label: String.t(),
          spec: spec_t(),
          inserted_at: integer() | nil,
          updated_at: integer() | nil,
          meta: map()
        }
end
