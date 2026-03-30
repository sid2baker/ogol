defmodule Ogol.Compiler.Normalize do
  @moduledoc false

  alias Ogol.Compiler.Model
  alias Ogol.Machine.Dsl
  alias Spark.Dsl.Verifier

  @spec from_dsl!(map(), module()) :: Model.Machine.t()
  def from_dsl!(dsl_state, module) do
    boundary = Verifier.get_entities(dsl_state, [:boundary])
    fields = Verifier.get_entities(dsl_state, [:memory])
    states = Verifier.get_entities(dsl_state, [:states])
    transitions = Verifier.get_entities(dsl_state, [:transitions])
    safety_rules = Verifier.get_entities(dsl_state, [:safety])
    dependencies = Verifier.get_entities(dsl_state, [:uses])

    machine =
      %Model.Machine{
        module: module,
        name: Verifier.get_option(dsl_state, [:machine], :name) || module_name(module),
        meaning: Verifier.get_option(dsl_state, [:machine], :meaning),
        hardware_ref: Verifier.get_option(dsl_state, [:machine], :hardware_ref),
        hardware_adapter: Verifier.get_option(dsl_state, [:machine], :hardware_adapter),
        facts: defaults(boundary, Dsl.Fact),
        fields: defaults(fields, Dsl.Field),
        outputs: defaults(boundary, Dsl.Output),
        commands: names(boundary, Dsl.Command),
        signals: names(boundary, Dsl.Signal),
        events: names(boundary, Dsl.Event),
        requests: names(boundary, Dsl.Request),
        dependencies: names(dependencies, Dsl.Dependency),
        states: normalize_states(states),
        transitions_by_source: normalize_transitions(transitions),
        safety_rules: normalize_safety_rules(safety_rules)
      }

    %{machine | initial_state: initial_state(states)}
  end

  defp module_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp defaults(items, module) do
    items
    |> Enum.filter(&(Map.get(&1, :__struct__) == module))
    |> Map.new(fn item -> {item.name, Map.get(item, :default)} end)
  end

  defp names(items, module) do
    items
    |> Enum.filter(&(Map.get(&1, :__struct__) == module))
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp normalize_states(states) do
    Map.new(states, fn state ->
      normalized =
        %Model.State{
          name: state.name,
          initial?: state.initial?,
          status: state.status,
          meaning: state.meaning,
          entries: normalize_actions(state.entries)
        }

      {state.name, normalized}
    end)
  end

  defp initial_state(states) do
    case Enum.find(states, & &1.initial?) do
      nil ->
        states
        |> List.first()
        |> case do
          nil -> nil
          state -> state.name
        end

      state ->
        state.name
    end
  end

  defp normalize_transitions(transitions) do
    transitions
    |> Enum.group_by(& &1.source)
    |> Map.new(fn {source, source_transitions} ->
      normalized =
        source_transitions
        |> Enum.sort_by(fn transition ->
          {-transition.priority, transition.source, transition.destination}
        end)
        |> Enum.map(fn transition ->
          %Model.Transition{
            source: transition.source,
            destination: transition.destination,
            trigger: normalize_trigger(transition.on),
            guard: transition.guard,
            priority: transition.priority,
            reenter?: transition.reenter?,
            meaning: transition.meaning,
            actions: normalize_actions(transition.actions)
          }
        end)

      {source, normalized}
    end)
  end

  defp normalize_trigger({family, name})
       when family in [:event, :request, :hardware, :state_timeout, :monitor, :link] and
              is_atom(name),
       do: {family, name}

  defp normalize_trigger(name) when is_atom(name), do: {:event, name}
  defp normalize_trigger(other), do: other

  defp normalize_safety_rules(rules) do
    Enum.map(rules, fn
      %Dsl.AlwaysSafety{check: check} ->
        %Model.SafetyRule{scope: :always, check: check}

      %Dsl.WhileInSafety{state: state, check: check} ->
        %Model.SafetyRule{scope: {:while_in, state}, check: check}
    end)
  end

  defp normalize_actions(actions) do
    Enum.map(actions, fn
      %Dsl.SetFact{name: name, value: value} ->
        %Model.Action{kind: :set_fact, args: %{name: name, value: value}}

      %Dsl.SetField{name: name, value: value} ->
        %Model.Action{kind: :set_field, args: %{name: name, value: value}}

      %Dsl.SetOutput{name: name, value: value} ->
        %Model.Action{kind: :set_output, args: %{name: name, value: value}}

      %Dsl.EmitSignal{name: name, data: data, meta: meta} ->
        %Model.Action{kind: :signal, args: %{name: name, data: data, meta: meta}}

      %Dsl.EmitCommand{name: name, data: data, meta: meta} ->
        %Model.Action{kind: :command, args: %{name: name, data: data, meta: meta}}

      %Dsl.Reply{value: value} ->
        %Model.Action{kind: :reply, args: %{value: value}}

      %Dsl.Internal{name: name, data: data, meta: meta} ->
        %Model.Action{kind: :internal, args: %{name: name, data: data, meta: meta}}

      %Dsl.StateTimeout{name: name, delay_ms: delay_ms, data: data, meta: meta} ->
        %Model.Action{
          kind: :state_timeout,
          args: %{name: name, delay_ms: delay_ms, data: data, meta: meta}
        }

      %Dsl.CancelTimeout{name: name} ->
        %Model.Action{kind: :cancel_timeout, args: %{name: name}}

      %Dsl.Invoke{target: target, skill: skill, args: args, meta: meta, timeout: timeout} ->
        %Model.Action{
          kind: :invoke,
          args: %{target: target, skill: skill, args: args, meta: meta, timeout: timeout}
        }

      %Dsl.Monitor{target: target, name: name} ->
        %Model.Action{kind: :monitor, args: %{target: target, name: name}}

      %Dsl.Demonitor{name: name} ->
        %Model.Action{kind: :demonitor, args: %{name: name}}

      %Dsl.Link{target: target} ->
        %Model.Action{kind: :link, args: %{target: target}}

      %Dsl.Unlink{target: target} ->
        %Model.Action{kind: :unlink, args: %{target: target}}

      %Dsl.CallbackAction{name: name} ->
        %Model.Action{kind: :callback, args: %{name: name}}

      %Dsl.ForeignAction{kind: kind, module: module, opts: opts} ->
        %Model.Action{kind: :foreign, args: %{kind: kind, module: module, opts: opts}}

      %Dsl.Stop{reason: reason} ->
        %Model.Action{kind: :stop, args: %{reason: reason}}

      %Dsl.Hibernate{} ->
        %Model.Action{kind: :hibernate, args: %{}}
    end)
  end
end
