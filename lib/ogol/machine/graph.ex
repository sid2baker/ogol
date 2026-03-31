defmodule Ogol.Machine.Graph do
  @moduledoc false

  @spec mermaid(map() | nil, keyword()) :: String.t() | nil
  def mermaid(model, opts \\ [])

  def mermaid(nil, _opts), do: nil

  def mermaid(model, opts) when is_map(model) do
    states = Map.get(model, :states, [])
    transitions = Map.get(model, :transitions, [])
    active_state = opts[:active_state] |> normalize_state_name()

    if states == [] do
      nil
    else
      initial_state =
        states
        |> Enum.find(&Map.get(&1, :initial?))
        |> case do
          nil -> List.first(states)
          state -> state
        end

      state_aliases = Map.new(states, &{state_name(&1), state_alias(state_name(&1))})

      lines =
        [
          "stateDiagram-v2",
          "[*] --> #{Map.fetch!(state_aliases, state_name(initial_state))}"
        ] ++
          Enum.map(states, &state_definition_line(&1, state_aliases)) ++
          Enum.map(transitions, &transition_line(&1, state_aliases)) ++
          class_lines(states, state_aliases, active_state)

      lines
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")
    end
  end

  defp state_definition_line(state, state_aliases) do
    name = state_name(state)
    alias_name = Map.fetch!(state_aliases, name)
    label = state_label(state)
    ~s(state "#{label}" as #{alias_name})
  end

  defp transition_line(transition, state_aliases) do
    source = transition |> Map.get(:source) |> normalize_state_name()
    destination = transition |> Map.get(:destination) |> normalize_state_name()

    if source && destination do
      label =
        transition
        |> transition_label()
        |> case do
          nil -> ""
          text -> " : #{text}"
        end

      "#{Map.get(state_aliases, source, state_alias(source))} --> #{Map.get(state_aliases, destination, state_alias(destination))}#{label}"
    else
      nil
    end
  end

  defp class_lines(states, state_aliases, active_state) do
    initial_classes =
      states
      |> Enum.filter(&Map.get(&1, :initial?))
      |> Enum.map(fn state ->
        "class #{Map.fetch!(state_aliases, state_name(state))} ogolInitial"
      end)

    active_classes =
      case active_state && Map.get(state_aliases, active_state) do
        nil -> []
        alias_name -> ["class #{alias_name} ogolActive"]
      end

    [
      "classDef ogolInitial fill:#0f766e,stroke:#14b8a6,color:#ecfeff,stroke-width:2px",
      "classDef ogolActive fill:#f59e0b,stroke:#facc15,color:#111827,stroke-width:3px"
      | initial_classes ++ active_classes
    ]
  end

  defp transition_label(transition) do
    trigger =
      transition
      |> Map.get(:trigger)
      |> blank_to_nil()

    meaning =
      transition
      |> Map.get(:meaning)
      |> blank_to_nil()

    [trigger, meaning]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      [single] -> single
      [head | tail] -> Enum.join([head | tail], " / ")
    end
  end

  defp state_label(state) do
    name = state_name(state)
    status = blank_to_nil(Map.get(state, :status))
    meaning = blank_to_nil(Map.get(state, :meaning))

    [name, status_label(name, status), meaning]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" / ")
  end

  defp status_label(name, status) when is_binary(name) and is_binary(status) do
    if String.downcase(name) == String.downcase(status), do: nil, else: status
  end

  defp status_label(_name, status), do: status

  defp state_name(state) do
    state
    |> Map.get(:name)
    |> normalize_state_name()
  end

  defp normalize_state_name(nil), do: nil

  defp normalize_state_name(name) do
    name
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp state_alias(name) do
    "state_" <>
      (name
       |> String.replace(~r/[^a-zA-Z0-9_]+/u, "_")
       |> String.replace(~r/_+/, "_")
       |> String.trim("_")
       |> case do
         "" -> "unnamed"
         value -> value
       end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: to_string(value)
end
