defmodule Ogol.Runtime.SafetyViolation do
  defexception [:message, :check, :state]

  @impl true
  def exception(opts) do
    check = Keyword.fetch!(opts, :check)
    state = Keyword.fetch!(opts, :state)

    %__MODULE__{
      check: check,
      state: state,
      message: "safety violation #{inspect(check)} in state #{inspect(state)}"
    }
  end
end
