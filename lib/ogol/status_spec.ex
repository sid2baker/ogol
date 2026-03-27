defmodule Ogol.StatusSpec do
  @moduledoc false

  @type item :: %{name: atom(), summary: String.t() | nil}

  @type t :: %__MODULE__{
          facts: [item()],
          outputs: [item()],
          fields: [item()]
        }

  defstruct facts: [], outputs: [], fields: []
end
