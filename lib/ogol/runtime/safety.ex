defmodule Ogol.Runtime.Safety do
  @moduledoc false

  @spec check!(
          module(),
          [Ogol.Machine.Compiler.Model.SafetyRule.t()],
          atom(),
          Ogol.Runtime.Data.t()
        ) ::
          :ok
  def check!(module, rules, state_name, data) do
    Enum.each(rules, fn rule ->
      if applies?(rule.scope, state_name) and
           not invoke_check(module, rule.check, state_name, data) do
        raise Ogol.Runtime.SafetyViolation, check: rule.check, state: state_name
      end
    end)
  end

  defp applies?(:always, _state_name), do: true
  defp applies?({:while_in, state}, state_name), do: state == state_name

  defp invoke_check(module, {:callback, name}, state_name, data) do
    cond do
      function_exported?(module, name, 2) -> apply(module, name, [state_name, data])
      function_exported?(module, name, 1) -> apply(module, name, [data])
      true -> raise UndefinedFunctionError, module: module, function: name, arity: 2
    end
  end

  defp invoke_check(_module, value, _state_name, _data), do: value == true
end
