defmodule Ogol.Runtime.Hardware.SupportSnapshot do
  @moduledoc false

  @type t :: %__MODULE__{
          id: binary(),
          kind: :runtime | :support,
          captured_at: integer(),
          summary: map(),
          payload: map()
        }

  @enforce_keys [:id, :kind, :captured_at, :summary, :payload]
  defstruct [:id, :kind, :captured_at, :summary, :payload]
end
