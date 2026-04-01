defmodule Ogol.Machine.Studio.Diagnostic do
  @moduledoc false

  @type t :: %__MODULE__{
          classification: :partial | :rejected,
          code: atom(),
          message: String.t(),
          section: atom() | nil,
          line: non_neg_integer() | nil,
          column: non_neg_integer() | nil
        }

  defstruct [
    :classification,
    :code,
    :message,
    :section,
    :line,
    :column
  ]
end
