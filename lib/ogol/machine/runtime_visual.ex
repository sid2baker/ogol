defmodule Ogol.Machine.RuntimeVisual do
  @moduledoc false

  alias Ogol.Machine.Graph

  @spec graph_model(module() | nil) :: map() | nil
  def graph_model(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :__ogol_machine__, 0) do
      machine = module.__ogol_machine__()

      %{
        machine_id: machine.name |> to_string(),
        module_name: module |> Atom.to_string() |> String.trim_leading("Elixir."),
        meaning: machine.meaning,
        states:
          machine.states
          |> Map.values()
          |> Enum.sort_by(fn state ->
            {state.name != machine.initial_state, to_string(state.name)}
          end)
          |> Enum.map(fn state ->
            %{
              name: to_string(state.name),
              initial?: state.name == machine.initial_state or state.initial?,
              status: state.status,
              meaning: state.meaning
            }
          end),
        transitions:
          machine.transitions_by_source
          |> Map.values()
          |> List.flatten()
          |> Enum.map(fn transition ->
            {family, trigger_name} = normalize_trigger(transition.trigger)

            %{
              source: to_string(transition.source),
              family: Atom.to_string(family),
              trigger: to_string(trigger_name),
              destination: to_string(transition.destination),
              meaning: transition.meaning
            }
          end)
      }
    end
  end

  def graph_model(_module), do: nil

  @spec diagram(map() | nil) :: String.t() | nil
  def diagram(%{module: module, current_state: current_state}) when is_atom(module) do
    module
    |> graph_model()
    |> Graph.mermaid(active_state: current_state)
  end

  def diagram(_machine), do: nil

  defp normalize_trigger({family, name})
       when family in [:event, :request, :hardware, :state_timeout] and is_atom(name),
       do: {family, name}

  defp normalize_trigger(name) when is_atom(name), do: {:event, name}
  defp normalize_trigger(_other), do: {:event, :unknown}
end
