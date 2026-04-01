defmodule Ogol.Machine.Studio.Lowering do
  @moduledoc false

  alias Ogol.Machine.Studio.Artifact
  alias Ogol.Machine.Studio.Model
  alias Ogol.Machine.Studio.Model.ActionNode
  alias Ogol.Machine.Studio.Model.BoundaryDecl
  alias Ogol.Machine.Studio.Model.FieldDecl
  alias Ogol.Machine.Studio.Model.StateNode
  alias Ogol.Machine.Studio.Model.TransitionEdge

  @boundary_key_by_kind %{
    fact: :facts,
    event: :events,
    request: :requests,
    command: :commands,
    output: :outputs,
    signal: :signals
  }

  @spec lower_artifact(Artifact.t()) ::
          {:ok, Model.t()} | {:error, Artifact.t()}
  def lower_artifact(%Artifact{compatibility: :fully_editable} = artifact) do
    lower_artifact_for_inspection(artifact)
  end

  def lower_artifact(%Artifact{} = artifact), do: {:error, artifact}

  @spec lower_artifact_for_inspection(Artifact.t()) ::
          {:ok, Model.t()} | {:error, Artifact.t()}
  def lower_artifact_for_inspection(%Artifact{} = artifact) do
    with {:ok, body} <- module_body(artifact.ast) do
      model =
        %Model{
          module: artifact.module,
          source_path: artifact.path,
          compatibility: artifact.compatibility
        }
        |> lower_module_forms(to_forms(body))
        |> finalize_model()

      {:ok, model}
    else
      :error -> {:error, artifact}
    end
  end

  defp module_body({:__block__, _, forms}) do
    case Enum.filter(forms, &match?({:defmodule, _, _}, &1)) do
      [{:defmodule, _, [_name_ast, [do: body]]}] -> {:ok, body}
      _ -> :error
    end
  end

  defp module_body({:defmodule, _, [_name_ast, [do: body]]}), do: {:ok, body}
  defp module_body(_), do: :error

  defp lower_module_forms(model, forms) do
    Enum.reduce(forms, model, fn
      {:machine, meta, args}, acc ->
        with {:ok, _prefix, body} <- split_do_args(args) do
          lower_machine_section(acc, to_forms(body), section_provenance(:machine, meta))
        else
          :error -> acc
        end

      {:boundary, meta, args}, acc ->
        with {:ok, _prefix, body} <- split_do_args(args) do
          lower_boundary_section(acc, to_forms(body), section_provenance(:boundary, meta))
        else
          :error -> acc
        end

      {:memory, meta, args}, acc ->
        with {:ok, _prefix, body} <- split_do_args(args) do
          lower_memory_section(acc, to_forms(body), section_provenance(:memory, meta))
        else
          :error -> acc
        end

      {:states, meta, args}, acc ->
        with {:ok, _prefix, body} <- split_do_args(args) do
          lower_states_section(acc, to_forms(body), section_provenance(:states, meta))
        else
          :error -> acc
        end

      {:transitions, meta, args}, acc ->
        with {:ok, _prefix, body} <- split_do_args(args) do
          lower_transitions_section(acc, to_forms(body), section_provenance(:transitions, meta))
        else
          :error -> acc
        end

      _other, acc ->
        acc
    end)
  end

  defp lower_machine_section(model, entries, section_provenance) do
    Enum.reduce(entries, put_provenance(model, {:section, :machine}, section_provenance), fn
      {:name, meta, [name]}, acc when is_atom(name) ->
        put_in(acc.metadata.name, name)
        |> put_provenance({:machine, :name}, provenance(meta))

      {:meaning, meta, [meaning]}, acc when is_binary(meaning) ->
        put_in(acc.metadata.meaning, meaning)
        |> put_provenance({:machine, :meaning}, provenance(meta))

      {:hardware_ref, meta, [hardware_ref]}, acc ->
        put_in(acc.metadata.hardware_ref, normalize_hardware_ref_literal(literal!(hardware_ref)))
        |> put_provenance({:machine, :hardware_ref}, provenance(meta))

      {:hardware_adapter, meta, [adapter_ast]}, acc ->
        case module_value(adapter_ast) do
          {:ok, adapter} ->
            put_in(acc.metadata.hardware_adapter, adapter)
            |> put_provenance({:machine, :hardware_adapter}, provenance(meta))

          :error ->
            acc
        end

      _entry, acc ->
        acc
    end)
  end

  defp lower_boundary_section(model, entries, section_provenance) do
    model = put_provenance(model, {:section, :boundary}, section_provenance)

    Enum.reduce(entries, model, fn entry, acc ->
      case lower_boundary_entry(entry) do
        {:ok, key, decl} ->
          put_boundary_decl(acc, key, decl)
          |> put_provenance({:boundary, key, decl.name}, decl.provenance)

        :skip ->
          acc
      end
    end)
  end

  defp lower_boundary_entry({kind, meta, args}) when kind in [:fact, :output] do
    {name, type, opts} = positional_and_opts(args, 2)

    {:ok, Map.fetch!(@boundary_key_by_kind, kind),
     %BoundaryDecl{
       kind: kind,
       name: name,
       type: type,
       default: Keyword.get(opts, :default),
       meaning: Keyword.get(opts, :meaning),
       public?: Keyword.get(opts, :public?, false),
       provenance: provenance(meta)
     }}
  end

  defp lower_boundary_entry({kind, meta, args})
       when kind in [:event, :request, :command, :signal] do
    {name, opts} =
      case positional_and_opts(args, 1) do
        {name, opts} -> {name, opts}
      end

    {:ok, Map.fetch!(@boundary_key_by_kind, kind),
     %BoundaryDecl{
       kind: kind,
       name: name,
       meaning: Keyword.get(opts, :meaning),
       skill?: boundary_skill_default(kind, opts),
       provenance: provenance(meta)
     }}
  end

  defp lower_boundary_entry(_entry), do: :skip

  defp lower_memory_section(model, entries, section_provenance) do
    model = put_provenance(model, {:section, :memory}, section_provenance)

    Enum.reduce(entries, model, fn
      {:field, meta, args}, acc ->
        {name, type, opts} = positional_and_opts(args, 2)

        decl = %FieldDecl{
          name: name,
          type: type,
          default: Keyword.get(opts, :default),
          meaning: Keyword.get(opts, :meaning),
          public?: Keyword.get(opts, :public?, false),
          provenance: provenance(meta)
        }

        put_field_decl(acc, decl)
        |> put_provenance({:memory, :field, name}, decl.provenance)

      _entry, acc ->
        acc
    end)
  end

  defp lower_states_section(model, entries, section_provenance) do
    model = put_provenance(model, {:section, :states}, section_provenance)

    Enum.reduce(entries, model, fn
      {:state, meta, [state_name | rest]}, acc when is_atom(state_name) ->
        body =
          case split_do_args(rest) do
            {:ok, _prefix, body} -> body
            :error -> []
          end

        {state_node, initial?} = lower_state_body(state_name, meta, to_forms(body))

        acc
        |> put_state_node(state_name, state_node)
        |> put_initial_state(state_name, initial?)
        |> put_provenance({:state, state_name}, state_node.provenance)

      _entry, acc ->
        acc
    end)
  end

  defp lower_state_body(state_name, meta, entries) do
    state =
      %StateNode{
        name: state_name,
        initial?: false,
        provenance: provenance(meta)
      }

    Enum.reduce(entries, {state, false}, fn
      {:initial?, _meta, [true]}, {acc, _} ->
        {%{acc | initial?: true}, true}

      {:status, _meta, [status]}, {acc, initial?} when is_binary(status) ->
        {%{acc | status: status}, initial?}

      {:meaning, _meta, [meaning]}, {acc, initial?} when is_binary(meaning) ->
        {%{acc | meaning: meaning}, initial?}

      {action_name, action_meta, action_args}, {acc, initial?}
      when is_atom(action_name) and is_list(action_args) ->
        action = lower_action(action_name, action_meta, action_args)
        {%{acc | entries: acc.entries ++ [action]}, initial?}

      _entry, tuple ->
        tuple
    end)
  end

  defp lower_transitions_section(model, entries, section_provenance) do
    model = put_provenance(model, {:section, :transitions}, section_provenance)

    transitions =
      Enum.flat_map(entries, fn
        {:transition, meta, [source, destination | rest]}
        when is_atom(source) and is_atom(destination) ->
          body =
            case split_do_args(rest) do
              {:ok, _prefix, body} -> body
              :error -> []
            end

          [lower_transition_body(source, destination, meta, to_forms(body))]

        _entry ->
          []
      end)

    %{model | transitions: model.transitions ++ transitions}
  end

  defp lower_transition_body(source, destination, meta, entries) do
    transition =
      %TransitionEdge{
        source: source,
        destination: destination,
        priority: 0,
        reenter?: false,
        guard: nil,
        provenance: provenance(meta)
      }

    Enum.reduce(entries, transition, fn
      {:on, _meta, [trigger_ast]}, acc ->
        %{acc | trigger: lower_trigger(trigger_ast)}

      {:guard, _meta, [guard_ast]}, acc ->
        %{acc | guard: guard_ast}

      {:priority, _meta, [priority]}, acc when is_integer(priority) ->
        %{acc | priority: priority}

      {:reenter?, _meta, [reenter?]}, acc when is_boolean(reenter?) ->
        %{acc | reenter?: reenter?}

      {:meaning, _meta, [meaning]}, acc when is_binary(meaning) ->
        %{acc | meaning: meaning}

      {action_name, action_meta, action_args}, acc
      when is_atom(action_name) and is_list(action_args) ->
        action = lower_action(action_name, action_meta, action_args)
        %{acc | actions: acc.actions ++ [action]}

      _entry, acc ->
        acc
    end)
  end

  defp lower_trigger(trigger_ast) do
    case literal_value(trigger_ast) do
      {:ok, [{family, name}]} when is_atom(family) and is_atom(name) ->
        {family, name}

      {:ok, {family, name}} when is_atom(family) and is_atom(name) ->
        {family, name}

      {:ok, name} when is_atom(name) ->
        {:event, name}

      _ ->
        trigger_ast
    end
  end

  defp lower_action(name, meta, args) do
    %ActionNode{
      kind: name,
      args: lower_action_args(name, args),
      provenance: provenance(meta)
    }
  end

  defp lower_action_args(:set_fact, [name, value]), do: %{name: name, value: literal!(value)}
  defp lower_action_args(:set_field, [name, value]), do: %{name: name, value: literal!(value)}
  defp lower_action_args(:set_output, [name, value]), do: %{name: name, value: literal!(value)}
  defp lower_action_args(:reply, [value]), do: %{value: literal!(value)}

  defp lower_action_args(kind, args) when kind in [:signal, :command] do
    {name, opts} = positional_and_opts(args, 1)

    %{
      name: name,
      data: Keyword.get(opts, :data, %{}),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  defp lower_action_args(:state_timeout, args) do
    {name, delay_ms, opts} = positional_and_opts(args, 2)

    %{
      name: name,
      delay_ms: delay_ms,
      data: Keyword.get(opts, :data, %{}),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  defp lower_action_args(:cancel_timeout, [name]), do: %{name: name}
  defp lower_action_args(_kind, args), do: %{raw: Enum.map(args, &literal_or_ast/1)}

  defp boundary_skill_default(:event, opts), do: Keyword.get(opts, :skill?, false)
  defp boundary_skill_default(:request, opts), do: Keyword.get(opts, :skill?, true)
  defp boundary_skill_default(_kind, _opts), do: nil

  defp positional_and_opts(args, arity) do
    {positional, trailing} = Enum.split(args, arity)

    opts =
      case trailing do
        [opts] when is_list(opts) ->
          if Keyword.keyword?(opts) do
            Enum.map(opts, fn {key, value} -> {key, literal!(value)} end)
          else
            []
          end

        [] ->
          []

        _ ->
          []
      end

    case positional do
      [one] ->
        {literal_or_ast(one), opts}

      [one, two] ->
        {literal_or_ast(one), literal_or_ast(two), opts}
    end
  end

  defp literal_or_ast(ast) do
    case literal_value(ast) do
      {:ok, value} ->
        value

      :error ->
        case module_value(ast) do
          {:ok, module} -> module
          :error -> ast
        end
    end
  end

  defp literal!(ast) do
    case literal_or_ast(ast) do
      value -> value
    end
  end

  defp normalize_hardware_ref_literal(refs) when is_list(refs) do
    if Keyword.keyword?(refs) do
      refs
    else
      Enum.sort_by(refs, &canonical_literal_sort_key/1)
    end
  end

  defp normalize_hardware_ref_literal(ref), do: ref

  defp canonical_literal_sort_key(value) when is_map(value) do
    {:map,
     value
     |> Enum.map(fn {key, inner} ->
       {canonical_literal_sort_key(key), canonical_literal_sort_key(inner)}
     end)
     |> Enum.sort()}
  end

  defp canonical_literal_sort_key(value) when is_list(value) do
    if Keyword.keyword?(value) do
      {:keyword,
       value
       |> Enum.map(fn {key, inner} ->
         {canonical_literal_sort_key(key), canonical_literal_sort_key(inner)}
       end)
       |> Enum.sort()}
    else
      {:list, Enum.map(value, &canonical_literal_sort_key/1)}
    end
  end

  defp canonical_literal_sort_key(value), do: value

  defp literal_value(ast) do
    if Macro.quoted_literal?(ast) do
      {value, _binding} = Code.eval_quoted(ast, [], __ENV__)
      {:ok, value}
    else
      :error
    end
  end

  defp module_value({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}
  defp module_value(atom) when is_atom(atom), do: {:ok, atom}
  defp module_value(_other), do: :error

  defp finalize_model(model) do
    transitions =
      Enum.sort_by(model.transitions, fn transition ->
        {
          transition.source,
          transition.destination,
          transition.trigger,
          transition.priority,
          transition.guard,
          transition.reenter?,
          transition.meaning,
          transition.actions |> Enum.map(&{&1.kind, &1.args})
        }
      end)

    %{model | transitions: transitions}
  end

  defp put_boundary_decl(model, key, decl) do
    current = Map.fetch!(model.boundary, key)
    %{model | boundary: Map.put(model.boundary, key, Map.put(current, decl.name, decl))}
  end

  defp put_field_decl(model, decl) do
    %{model | memory: %{model.memory | fields: Map.put(model.memory.fields, decl.name, decl)}}
  end

  defp put_state_node(model, state_name, state_node) do
    %{
      model
      | states: %{model.states | nodes: Map.put(model.states.nodes, state_name, state_node)}
    }
  end

  defp put_initial_state(model, state_name, true),
    do: put_in(model.states.initial_state, state_name)

  defp put_initial_state(model, _state_name, false), do: model

  defp put_provenance(model, key, provenance) do
    put_in(model.provenance_index[key], provenance)
  end

  defp section_provenance(section, meta) do
    provenance(meta) |> Map.put(:section, section)
  end

  defp provenance(meta) do
    %{
      line: meta[:line],
      column: meta[:column]
    }
  end

  defp split_do_args(args) when is_list(args) do
    case Enum.split(args, -1) do
      {prefix, [[do: body]]} -> {:ok, prefix, body}
      _ -> :error
    end
  end

  defp split_do_args(_), do: :error

  defp to_forms({:__block__, _, forms}), do: forms
  defp to_forms(nil), do: []
  defp to_forms(form), do: [form]
end
