defmodule Ogol.Authoring.MachinePrinter do
  @moduledoc false

  alias Ogol.Authoring.MachineModel
  alias Ogol.Authoring.MachineModel.ActionNode
  alias Ogol.Authoring.MachineModel.BoundaryDecl
  alias Ogol.Authoring.MachineModel.DependencyDecl
  alias Ogol.Authoring.MachineModel.FieldDecl
  alias Ogol.Authoring.MachineModel.StateNode

  @boundary_order [:facts, :events, :requests, :commands, :outputs, :signals]

  @spec print(MachineModel.t()) :: String.t()
  def print(%MachineModel{} = model) do
    model
    |> to_quoted()
    |> Code.quoted_to_algebra()
    |> Inspect.Algebra.format(98)
    |> IO.iodata_to_binary()
  end

  @spec to_quoted(MachineModel.t()) :: Macro.t()
  def to_quoted(%MachineModel{} = model) do
    {:defmodule, [],
     [
       alias_ast(canonical_module(model)),
       [
         do:
           do_block([
             {:use, [], [alias_ast(Ogol.Machine)]}
             | section_asts(model)
           ])
       ]
     ]}
  end

  defp section_asts(model) do
    [
      machine_section_ast(model),
      uses_section_ast(model),
      boundary_section_ast(model),
      memory_section_ast(model),
      states_section_ast(model),
      transitions_section_ast(model)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp machine_section_ast(model) do
    entries =
      [
        maybe_call(:name, [model.metadata.name]),
        maybe_call(:meaning, [model.metadata.meaning]),
        maybe_call(:hardware_ref, [value_ast(model.metadata.hardware_ref)]),
        maybe_call(:hardware_adapter, [module_ast_or_literal(model.metadata.hardware_adapter)])
      ]
      |> Enum.reject(&is_nil/1)

    section_ast(:machine, entries)
  end

  defp boundary_section_ast(model) do
    entries =
      @boundary_order
      |> Enum.flat_map(fn key ->
        model.boundary
        |> Map.fetch!(key)
        |> Map.values()
        |> Enum.sort_by(& &1.name)
        |> Enum.map(&boundary_decl_ast/1)
      end)

    section_ast(:boundary, entries)
  end

  defp uses_section_ast(model) do
    entries =
      model.dependencies
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&dependency_decl_ast/1)

    section_ast(:uses, entries)
  end

  defp memory_section_ast(model) do
    entries =
      model.memory.fields
      |> Map.values()
      |> Enum.sort_by(& &1.name)
      |> Enum.map(&field_decl_ast/1)

    section_ast(:memory, entries)
  end

  defp states_section_ast(model) do
    entries =
      model.states.nodes
      |> Map.values()
      |> Enum.sort_by(fn %StateNode{name: name} ->
        {name != model.states.initial_state, name}
      end)
      |> Enum.map(fn state ->
        body =
          [
            if(state.name == model.states.initial_state or state.initial?,
              do: {:initial?, [], [true]},
              else: nil
            ),
            maybe_call(:status, [state.status]),
            maybe_call(:meaning, [state.meaning])
            | Enum.map(state.entries, &action_ast/1)
          ]
          |> Enum.reject(&is_nil/1)

        {:state, [], [state.name, [do: do_block(body)]]}
      end)

    section_ast(:states, entries)
  end

  defp transitions_section_ast(model) do
    entries =
      Enum.map(model.transitions, fn transition ->
        body =
          [
            {:on, [], [trigger_ast(transition.trigger)]},
            if(transition.guard, do: {:guard, [], [transition.guard]}, else: nil),
            if(transition.priority not in [nil, 0],
              do: {:priority, [], [transition.priority]},
              else: nil
            ),
            if(transition.reenter?, do: {:reenter?, [], [true]}, else: nil),
            maybe_call(:meaning, [transition.meaning])
            | Enum.map(transition.actions, &action_ast/1)
          ]
          |> Enum.reject(&is_nil/1)

        {:transition, [], [transition.source, transition.destination, [do: do_block(body)]]}
      end)

    section_ast(:transitions, entries)
  end

  defp boundary_decl_ast(%BoundaryDecl{kind: kind, name: name, type: type} = decl)
       when kind in [:fact, :output] do
    opts =
      []
      |> maybe_keyword(:default, decl.default)
      |> maybe_keyword(:meaning, decl.meaning)
      |> maybe_keyword(:public?, decl.public?, false)

    call_ast(kind, [name, type], opts)
  end

  defp boundary_decl_ast(%BoundaryDecl{kind: kind, name: name, meaning: meaning, skill?: skill?})
       when kind in [:event, :request, :command, :signal] do
    opts =
      []
      |> maybe_keyword(:meaning, meaning)
      |> maybe_skill_keyword(kind, skill?)

    call_ast(kind, [name], opts)
  end

  defp dependency_decl_ast(%DependencyDecl{} = decl) do
    opts =
      []
      |> maybe_keyword(:meaning, decl.meaning)
      |> maybe_keyword(:skills, decl.skills, [])
      |> maybe_keyword(:signals, decl.signals, [])
      |> maybe_keyword(:status, decl.status, [])

    call_ast(:dependency, [decl.name], opts)
  end

  defp field_decl_ast(%FieldDecl{
         name: name,
         type: type,
         default: default,
         meaning: meaning,
         public?: public?
       }) do
    opts =
      []
      |> maybe_keyword(:default, default)
      |> maybe_keyword(:meaning, meaning)
      |> maybe_keyword(:public?, public?, false)

    call_ast(:field, [name, type], opts)
  end

  defp action_ast(%ActionNode{kind: :set_fact, args: %{name: name, value: value}}),
    do: {:set_fact, [], [name, value_ast(value)]}

  defp action_ast(%ActionNode{kind: :set_field, args: %{name: name, value: value}}),
    do: {:set_field, [], [name, value_ast(value)]}

  defp action_ast(%ActionNode{kind: :set_output, args: %{name: name, value: value}}),
    do: {:set_output, [], [name, value_ast(value)]}

  defp action_ast(%ActionNode{kind: :reply, args: %{value: value}}),
    do: {:reply, [], [value_ast(value)]}

  defp action_ast(%ActionNode{kind: kind, args: %{name: name, data: data, meta: meta}})
       when kind in [:signal, :command] do
    opts =
      []
      |> maybe_keyword(:data, data, %{})
      |> maybe_keyword(:meta, meta, %{})

    call_ast(kind, [name], opts)
  end

  defp action_ast(%ActionNode{
         kind: :invoke,
         args: %{target: target, skill: skill, args: invoke_args, meta: meta, timeout: timeout}
       }) do
    opts =
      []
      |> maybe_keyword(:args, invoke_args, %{})
      |> maybe_keyword(:meta, meta, %{})
      |> maybe_keyword(:timeout, timeout, 5_000)

    call_ast(:invoke, [target, skill], opts)
  end

  defp action_ast(%ActionNode{
         kind: :state_timeout,
         args: %{name: name, delay_ms: delay_ms, data: data, meta: meta}
       }) do
    opts =
      []
      |> maybe_keyword(:data, data, %{})
      |> maybe_keyword(:meta, meta, %{})

    call_ast(:state_timeout, [name, delay_ms], opts)
  end

  defp action_ast(%ActionNode{kind: :cancel_timeout, args: %{name: name}}),
    do: {:cancel_timeout, [], [name]}

  defp action_ast(%ActionNode{kind: kind, args: %{raw: raw}}),
    do: {kind, [], Enum.map(raw, &value_ast/1)}

  defp action_ast(%ActionNode{kind: kind, args: args}) do
    {kind, [], [Macro.escape(args)]}
  end

  defp maybe_skill_keyword(opts, :event, true), do: opts ++ [skill?: true]
  defp maybe_skill_keyword(opts, :request, false), do: opts ++ [skill?: false]
  defp maybe_skill_keyword(opts, _kind, _value), do: opts

  defp maybe_call(_name, [nil]), do: nil
  defp maybe_call(name, [arg]), do: {name, [], [arg]}

  defp call_ast(name, positional, []), do: {name, [], Enum.map(positional, &value_ast/1)}

  defp call_ast(name, positional, opts) do
    {name, [], Enum.map(positional, &value_ast/1) ++ [keyword_ast(opts)]}
  end

  defp section_ast(_section_name, []), do: nil
  defp section_ast(section_name, entries), do: {section_name, [], [[do: do_block(entries)]]}

  defp trigger_ast({family, name}) when family in [:request, :event],
    do: value_ast({family, name})

  defp trigger_ast(other), do: value_ast(other)

  defp alias_ast(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.map(&String.to_atom/1)
    |> then(&{:__aliases__, [], &1})
  end

  defp module_ast_or_literal(nil), do: nil
  defp module_ast_or_literal(module) when is_atom(module), do: alias_ast(module)

  defp canonical_module(%MachineModel{module: module, metadata: %{name: name}})
       when is_atom(name) and is_atom(module) do
    case Module.split(module) do
      [] ->
        Module.concat([Macro.camelize(Atom.to_string(name))])

      parts ->
        prefix = Enum.drop(parts, -1)
        Module.concat(prefix ++ [Macro.camelize(Atom.to_string(name))])
    end
  end

  defp canonical_module(%MachineModel{metadata: %{name: name}}) when is_atom(name) do
    Module.concat([Ogol, Authored, Macro.camelize(Atom.to_string(name))])
  end

  defp canonical_module(%MachineModel{module: module}) when is_atom(module), do: module

  defp keyword_ast(opts) do
    Enum.map(opts, fn {key, value} -> {key, value_ast(value)} end)
  end

  defp maybe_keyword(opts, _key, nil), do: opts
  defp maybe_keyword(opts, key, value), do: opts ++ [{key, value}]
  defp maybe_keyword(opts, _key, value, default) when value == default, do: opts
  defp maybe_keyword(opts, key, value, _default), do: opts ++ [{key, value}]

  defp do_block([]), do: nil
  defp do_block([form]), do: form
  defp do_block(forms), do: {:__block__, [], forms}

  defp value_ast(value) when is_list(value) do
    if Keyword.keyword?(value) do
      keyword_ast(value)
    else
      Enum.map(value, &value_ast/1)
    end
  end

  defp value_ast(value) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, inner} -> {value_ast(key), value_ast(inner)} end)
    |> then(&{:%{}, [], &1})
  end

  defp value_ast({left, right}), do: {:{}, [], [value_ast(left), value_ast(right)]}

  defp value_ast({name, meta, args} = ast) when is_atom(name) and is_list(meta) and is_list(args),
    do: ast

  defp value_ast({left, middle, right}),
    do: {:{}, [], [value_ast(left), value_ast(middle), value_ast(right)]}

  defp value_ast(value) when is_atom(value) do
    if match?("Elixir." <> _, Atom.to_string(value)) do
      alias_ast(value)
    else
      Macro.escape(value)
    end
  end

  defp value_ast(value), do: Macro.escape(value)
end
