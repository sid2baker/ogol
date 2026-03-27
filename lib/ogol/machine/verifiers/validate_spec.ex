defmodule Ogol.Machine.Verifiers.ValidateSpec do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Ogol.Machine.Dsl
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    states = Spark.Dsl.Verifier.get_entities(dsl_state, [:states])
    transitions = Spark.Dsl.Verifier.get_entities(dsl_state, [:transitions])
    safety_rules = Spark.Dsl.Verifier.get_entities(dsl_state, [:safety])

    facts =
      Spark.Dsl.Verifier.get_entities(dsl_state, [:boundary])
      |> Enum.filter(&match?(%Dsl.Fact{}, &1))

    outputs =
      Spark.Dsl.Verifier.get_entities(dsl_state, [:boundary])
      |> Enum.filter(&match?(%Dsl.Output{}, &1))

    signals =
      Spark.Dsl.Verifier.get_entities(dsl_state, [:boundary])
      |> Enum.filter(&match?(%Dsl.Signal{}, &1))

    commands =
      Spark.Dsl.Verifier.get_entities(dsl_state, [:boundary])
      |> Enum.filter(&match?(%Dsl.Command{}, &1))

    requests =
      Spark.Dsl.Verifier.get_entities(dsl_state, [:boundary])
      |> Enum.filter(&match?(%Dsl.Request{}, &1))

    events =
      Spark.Dsl.Verifier.get_entities(dsl_state, [:boundary])
      |> Enum.filter(&match?(%Dsl.Event{}, &1))

    fields = Spark.Dsl.Verifier.get_entities(dsl_state, [:memory])
    dependencies = Spark.Dsl.Verifier.get_entities(dsl_state, [:uses])

    with :ok <- ensure_states_exist(dsl_state, states),
         :ok <- ensure_single_initial_state(dsl_state, states),
         :ok <- validate_transition_states(dsl_state, states, transitions),
         :ok <- validate_transition_triggers(dsl_state, requests, events, transitions),
         :ok <- validate_safety_states(dsl_state, states, safety_rules),
         :ok <-
           validate_actions(
             dsl_state,
             states,
             transitions,
             facts,
             fields,
             outputs,
             signals,
             commands,
             dependencies
           ) do
      :ok
    end
  end

  defp ensure_states_exist(dsl_state, []) do
    {:error, dsl_error(dsl_state, "a machine must declare at least one state")}
  end

  defp ensure_states_exist(_dsl_state, _states), do: :ok

  defp ensure_single_initial_state(dsl_state, states) do
    case Enum.count(states, & &1.initial?) do
      1 -> :ok
      0 -> {:error, dsl_error(dsl_state, "exactly one state must be marked `initial?: true`")}
      _ -> {:error, dsl_error(dsl_state, "only one state may be marked `initial?: true`")}
    end
  end

  defp validate_transition_states(dsl_state, states, transitions) do
    state_names = MapSet.new(Enum.map(states, & &1.name))

    Enum.reduce_while(transitions, :ok, fn transition, :ok ->
      cond do
        transition.source not in state_names ->
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "transition references unknown source state #{inspect(transition.source)}",
              transition
            )}}

        transition.destination not in state_names ->
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "transition references unknown destination state #{inspect(transition.destination)}",
              transition
            )}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_transition_triggers(dsl_state, requests, events, transitions) do
    request_names = MapSet.new(Enum.map(requests, & &1.name))
    event_names = MapSet.new(Enum.map(events, & &1.name))

    Enum.reduce_while(transitions, :ok, fn transition, :ok ->
      case validate_trigger(transition.on, request_names, event_names) do
        :ok ->
          {:cont, :ok}

        {:error, message} ->
          {:halt, {:error, dsl_error(dsl_state, message, transition)}}
      end
    end)
  end

  defp validate_trigger({:request, name}, request_names, _event_names) when is_atom(name) do
    if MapSet.member?(request_names, name) do
      :ok
    else
      {:error, "transition references unknown request trigger #{inspect(name)}"}
    end
  end

  defp validate_trigger({:event, name}, _request_names, event_names) when is_atom(name) do
    if MapSet.member?(event_names, name) do
      :ok
    else
      {:error, "transition references unknown event trigger #{inspect(name)}"}
    end
  end

  defp validate_trigger({:hardware, name}, _request_names, _event_names) when is_atom(name),
    do: :ok

  defp validate_trigger({:state_timeout, name}, _request_names, _event_names) when is_atom(name),
    do: :ok

  defp validate_trigger({:monitor, name}, _request_names, _event_names) when is_atom(name),
    do: :ok

  defp validate_trigger({:link, name}, _request_names, _event_names) when is_atom(name),
    do: :ok

  defp validate_trigger(name, request_names, event_names) when is_atom(name) do
    request? = MapSet.member?(request_names, name)
    event? = MapSet.member?(event_names, name)

    cond do
      event? and not request? ->
        :ok

      request? and not event? ->
        {:error,
         "transition uses bare trigger #{inspect(name)} for a request-only boundary; write on({:request, #{inspect(name)}})"}

      request? and event? ->
        {:error,
         "transition uses ambiguous bare trigger #{inspect(name)}; write on({:event, #{inspect(name)}}) or on({:request, #{inspect(name)}})"}

      true ->
        {:error, "transition references unknown trigger #{inspect(name)}"}
    end
  end

  defp validate_trigger(other, _request_names, _event_names),
    do: {:error, "transition references unknown trigger #{inspect(other)}"}

  defp validate_safety_states(dsl_state, states, safety_rules) do
    state_names = MapSet.new(Enum.map(states, & &1.name))

    Enum.reduce_while(safety_rules, :ok, fn
      %Dsl.AlwaysSafety{}, :ok ->
        {:cont, :ok}

      %Dsl.WhileInSafety{state: state} = rule, :ok ->
        if MapSet.member?(state_names, state) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "safety rule references unknown state #{inspect(state)}",
              rule
            )}}
        end
    end)
  end

  defp validate_actions(
         dsl_state,
         states,
         transitions,
         facts,
         fields,
         outputs,
         signals,
         commands,
         dependencies
       ) do
    fact_names = MapSet.new(Enum.map(facts, & &1.name))
    field_names = MapSet.new(Enum.map(fields, & &1.name))
    output_names = MapSet.new(Enum.map(outputs, & &1.name))
    signal_names = MapSet.new(Enum.map(signals, & &1.name))
    command_names = MapSet.new(Enum.map(commands, & &1.name))
    target_names = MapSet.new(Enum.map(dependencies, & &1.name))

    with :ok <-
           validate_state_entry_actions(
             dsl_state,
             states,
             fact_names,
             field_names,
             output_names,
             signal_names,
             command_names,
             target_names
           ),
         :ok <-
           validate_transition_actions(
             dsl_state,
             transitions,
             fact_names,
             field_names,
             output_names,
             signal_names,
             command_names,
             target_names
           ) do
      :ok
    end
  end

  defp validate_state_entry_actions(
         dsl_state,
         states,
         fact_names,
         field_names,
         output_names,
         signal_names,
         command_names,
         target_names
       ) do
    Enum.reduce_while(states, :ok, fn state, :ok ->
      case validate_action_list(
             state.entries,
             fact_names,
             field_names,
             output_names,
             signal_names,
             command_names,
             target_names
           ) do
        :ok ->
          {:cont, :ok}

        {:error, message} ->
          {:halt,
           {:error, dsl_error(dsl_state, "state #{inspect(state.name)} #{message}", state)}}
      end
    end)
  end

  defp validate_transition_actions(
         dsl_state,
         transitions,
         fact_names,
         field_names,
         output_names,
         signal_names,
         command_names,
         target_names
       ) do
    Enum.reduce_while(transitions, :ok, fn transition, :ok ->
      case validate_action_list(
             transition.actions,
             fact_names,
             field_names,
             output_names,
             signal_names,
             command_names,
             target_names
           ) do
        :ok ->
          {:cont, :ok}

        {:error, message} ->
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "transition #{inspect(transition.source)} -> #{inspect(transition.destination)} #{message}",
              transition
            )}}
      end
    end)
  end

  defp validate_action_list(
         actions,
         fact_names,
         field_names,
         output_names,
         signal_names,
         command_names,
         target_names
       ) do
    Enum.reduce_while(actions, :ok, fn action, :ok ->
      case validate_action(
             action,
             fact_names,
             field_names,
             output_names,
             signal_names,
             command_names,
             target_names
           ) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_action(
         %Dsl.SetFact{name: name},
         fact_names,
         _field_names,
         _output_names,
         _signal_names,
         _command_names,
         _target_names
       ) do
    if MapSet.member?(fact_names, name),
      do: :ok,
      else: {:error, "references unknown fact #{inspect(name)}"}
  end

  defp validate_action(
         %Dsl.SetField{name: name},
         _fact_names,
         field_names,
         _output_names,
         _signal_names,
         _command_names,
         _target_names
       ) do
    if MapSet.member?(field_names, name),
      do: :ok,
      else: {:error, "references unknown field #{inspect(name)}"}
  end

  defp validate_action(
         %Dsl.SetOutput{name: name},
         _fact_names,
         _field_names,
         output_names,
         _signal_names,
         _command_names,
         _target_names
       ) do
    if MapSet.member?(output_names, name),
      do: :ok,
      else: {:error, "references unknown output #{inspect(name)}"}
  end

  defp validate_action(
         %Dsl.EmitSignal{name: name},
         _fact_names,
         _field_names,
         _output_names,
         signal_names,
         _command_names,
         _target_names
       ) do
    if MapSet.member?(signal_names, name),
      do: :ok,
      else: {:error, "references unknown signal #{inspect(name)}"}
  end

  defp validate_action(
         %Dsl.EmitCommand{name: name},
         _fact_names,
         _field_names,
         _output_names,
         _signal_names,
         command_names,
         _target_names
       ) do
    if MapSet.member?(command_names, name),
      do: :ok,
      else: {:error, "references unknown command #{inspect(name)}"}
  end

  defp validate_action(
         %Dsl.Invoke{target: target},
         _fact_names,
         _field_names,
         _output_names,
         _signal_names,
         _command_names,
         target_names
       ) do
    if MapSet.member?(target_names, target),
      do: :ok,
      else: {:error, "references unknown dependency target #{inspect(target)}"}
  end

  defp validate_action(
         %Dsl.Monitor{target: target},
         _fact_names,
         _field_names,
         _output_names,
         _signal_names,
         _command_names,
         target_names
       ) do
    validate_process_target(target, target_names)
  end

  defp validate_action(
         %Dsl.Link{target: target},
         _fact_names,
         _field_names,
         _output_names,
         _signal_names,
         _command_names,
         target_names
       ) do
    validate_process_target(target, target_names)
  end

  defp validate_action(
         %Dsl.Unlink{target: target},
         _fact_names,
         _field_names,
         _output_names,
         _signal_names,
         _command_names,
         target_names
       ) do
    validate_process_target(target, target_names)
  end

  defp validate_action(
         _action,
         _fact_names,
         _field_names,
         _output_names,
         _signal_names,
         _command_names,
         _target_names
       ),
       do: :ok

  defp validate_process_target(target, target_names) when is_atom(target) do
    if MapSet.member?(target_names, target),
      do: :ok,
      else: {:error, "references unknown process target #{inspect(target)}"}
  end

  defp validate_process_target(_target, _target_names), do: :ok

  defp dsl_error(dsl_state, message, entity \\ nil) do
    DslError.exception(
      message: message,
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: entity && Spark.Dsl.Entity.anno(entity)
    )
  end
end
