defmodule Ogol.Machine.Compiler.Model.Transition do
  @moduledoc false

  defstruct [
    :source,
    :destination,
    :trigger,
    :guard,
    :priority,
    :reenter?,
    :meaning,
    actions: []
  ]
end
