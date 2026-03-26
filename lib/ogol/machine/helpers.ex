defmodule Ogol.Machine.Helpers do
  @moduledoc false

  defmacro callback(name) when is_atom(name) do
    quote do
      {:callback, unquote(name)}
    end
  end
end
