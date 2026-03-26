defmodule Ogol.Compiler.Model.State do
  @moduledoc false

  defstruct [:name, :initial?, :status, :meaning, entries: []]
end
