defmodule Ogol.Machine.Source do
  @moduledoc false

  alias Ogol.Authoring.MachineModel
  alias Ogol.Authoring.MachineModel.ActionNode
  alias Ogol.Authoring.MachineModel.BoundaryDecl
  alias Ogol.Authoring.MachineModel.StateNode
  alias Ogol.Authoring.MachineModel.TransitionEdge
  alias Ogol.Authoring.MachineLowering
  alias Ogol.Authoring.{MachinePrinter, MachineSource}
  alias Ogol.Machine.Form, as: MachineForm

  @spec to_source(map()) :: String.t()
  def to_source(model) when is_map(model) do
    model
    |> MachineForm.normalize_model()
    |> to_machine_model()
    |> MachinePrinter.print()
  end

  @spec from_source(String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def from_source(source) when is_binary(source) do
    case MachineSource.load_model_source(source) do
      {:ok, %MachineModel{} = model} ->
        case unsupported_features(model) do
          [] -> {:ok, model |> from_machine_model() |> MachineForm.normalize_model()}
          diagnostics -> {:error, diagnostics}
        end

      {:error, artifact} ->
        {:error, Enum.map(artifact.diagnostics, &format_diagnostic/1)}
    end
  end

  @spec graph_model_from_source(String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def graph_model_from_source(source) when is_binary(source) do
    with {:ok, artifact} <- MachineSource.load_source(source),
         {:ok, %MachineModel{} = model} <- MachineLowering.lower_artifact_for_inspection(artifact) do
      {:ok, graph_model_from_machine_model(model)}
    else
      {:error, artifact} ->
        {:error, Enum.map(artifact.diagnostics, &format_diagnostic/1)}

      {:ok, artifact} ->
        {:error, Enum.map(artifact.diagnostics, &format_diagnostic/1)}

      _other ->
        {:error, ["machine source could not be projected for inspection"]}
    end
  end

  @spec config_projection_from_source(String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def config_projection_from_source(source) when is_binary(source) do
    with {:ok, artifact} <- MachineSource.load_source(source),
         {:ok, %MachineModel{} = model} <- MachineLowering.lower_artifact_for_inspection(artifact) do
      {:ok, config_projection_from_machine_model(model)}
    else
      {:error, artifact} ->
        {:error, Enum.map(artifact.diagnostics, &format_diagnostic/1)}

      {:ok, artifact} ->
        {:error, Enum.map(artifact.diagnostics, &format_diagnostic/1)}

      _other ->
        {:error, ["machine source could not be projected for config view"]}
    end
  end

  @spec module_from_source(String.t()) :: {:ok, module()} | {:error, :module_not_found}
  def module_from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, module_ast} <- extract_module_ast(ast) do
      {:ok, module_from_ast!(module_ast)}
    else
      _ -> {:error, :module_not_found}
    end
  end

  def module_from_name!(module_name) do
    module_name
    |> to_string()
    |> String.trim()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
    |> Module.concat()
  end

  def summary(model) when is_map(model) do
    "#{length(model.states)} states, #{length(model.transitions)} transitions"
  end

  defp extract_module_ast({:__block__, _, [single]}), do: extract_module_ast(single)
  defp extract_module_ast({:defmodule, _, [module_ast, _body]}), do: {:ok, module_ast}
  defp extract_module_ast(_other), do: {:error, :module_not_found}

  defp module_from_ast!({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_from_ast!(atom) when is_atom(atom), do: atom

  defp to_machine_model(model) do
    initial_state =
      model.states
      |> Enum.find(& &1.initial?)
      |> case do
        nil -> List.first(model.states)
        state -> state
      end

    %MachineModel{
      module: module_from_name!(model.module_name),
      metadata: %{
        name: name_atom(model.machine_id),
        meaning: model.meaning,
        hardware_ref: nil,
        hardware_adapter: nil
      },
      boundary: %{
        facts: %{},
        events: boundary_map(Map.get(model, :events, []), :event, false),
        requests: boundary_map(model.requests, :request, true),
        commands: boundary_map(model.commands, :command, nil),
        outputs: %{},
        signals: boundary_map(model.signals, :signal, nil)
      },
      memory: %{fields: %{}},
      states: %{
        nodes:
          Map.new(model.states, fn state ->
            atom_name = name_atom(state.name)

            {atom_name,
             %StateNode{
               name: atom_name,
               initial?: state.initial?,
               status: blank_to_nil(state.status),
               meaning: blank_to_nil(state.meaning),
               entries: [],
               provenance: nil
             }}
          end),
        initial_state: name_atom(initial_state.name)
      },
      transitions:
        Enum.map(model.transitions, fn transition ->
          {family, _trigger_name} = normalize_transition_trigger(transition)

          %TransitionEdge{
            source: name_atom(transition.source),
            destination: name_atom(transition.destination),
            trigger: {String.to_atom(transition.family), name_atom(transition.trigger)},
            guard: nil,
            priority: 0,
            reenter?: false,
            meaning: blank_to_nil(transition.meaning),
            actions: default_transition_actions(family),
            provenance: nil
          }
        end),
      safety: [],
      children: [],
      compatibility: :fully_editable
    }
  end

  defp from_machine_model(%MachineModel{} = model) do
    %{
      machine_id: atom_name_to_string(model.metadata.name),
      module_name: module_name_from_model(model),
      meaning: model.metadata.meaning,
      requests: boundary_rows(model.boundary.requests),
      events: boundary_rows(model.boundary.events),
      commands: boundary_rows(model.boundary.commands),
      signals: boundary_rows(model.boundary.signals),
      states:
        model.states.nodes
        |> Map.values()
        |> Enum.sort_by(fn state ->
          {state.name != model.states.initial_state, atom_name_to_string(state.name)}
        end)
        |> Enum.map(fn state ->
          %{
            name: atom_name_to_string(state.name),
            initial?: state.name == model.states.initial_state or state.initial?,
            status: state.status,
            meaning: state.meaning
          }
        end),
      transitions:
        model.transitions
        |> Enum.map(fn transition ->
          {family, trigger_name} = normalize_trigger(transition.trigger)

          %{
            source: atom_name_to_string(transition.source),
            family: Atom.to_string(family),
            trigger: atom_name_to_string(trigger_name),
            destination: atom_name_to_string(transition.destination),
            meaning: transition.meaning
          }
        end)
    }
  end

  defp graph_model_from_machine_model(%MachineModel{} = model) do
    %{
      machine_id: atom_name_to_string(model.metadata.name),
      module_name: module_name_from_model(model),
      meaning: model.metadata.meaning,
      states:
        model.states.nodes
        |> Map.values()
        |> Enum.sort_by(fn state ->
          {state.name != model.states.initial_state, atom_name_to_string(state.name)}
        end)
        |> Enum.map(fn state ->
          %{
            name: atom_name_to_string(state.name),
            initial?: state.name == model.states.initial_state or state.initial?,
            status: state.status,
            meaning: state.meaning
          }
        end),
      transitions:
        model.transitions
        |> Enum.map(fn transition ->
          {family, trigger_name} = normalize_graph_trigger(transition.trigger)

          %{
            source: atom_name_to_string(transition.source),
            family: Atom.to_string(family),
            trigger: atom_name_to_string(trigger_name),
            destination: atom_name_to_string(transition.destination),
            meaning: transition.meaning
          }
        end)
    }
  end

  defp config_projection_from_machine_model(%MachineModel{} = model) do
    %{
      machine_id: atom_name_to_string(model.metadata.name),
      module_name: module_name_from_model(model),
      meaning: model.metadata.meaning,
      compatibility: model.compatibility,
      requests: boundary_projection_rows(model.boundary.requests),
      events: boundary_projection_rows(model.boundary.events),
      commands: boundary_projection_rows(model.boundary.commands),
      signals: boundary_projection_rows(model.boundary.signals),
      facts: boundary_projection_rows(model.boundary.facts),
      outputs: boundary_projection_rows(model.boundary.outputs),
      memory_fields: field_projection_rows(model.memory.fields),
      states: graph_model_from_machine_model(model).states,
      transitions: graph_model_from_machine_model(model).transitions
    }
  end

  defp unsupported_features(%MachineModel{} = model) do
    []
    |> maybe_add(model.metadata.hardware_ref != nil, "hardware bindings require source editing")
    |> maybe_add(
      model.metadata.hardware_adapter != nil,
      "hardware adapter requires source editing"
    )
    |> maybe_add(model.boundary.facts != %{}, "facts require source editing")
    |> maybe_add(model.boundary.outputs != %{}, "outputs require source editing")
    |> maybe_add(model.memory.fields != %{}, "memory fields require source editing")
    |> maybe_add(model.safety != [], "safety rules require source editing")
    |> maybe_add(model.children != [], "child machines require source editing")
    |> maybe_add(
      Enum.any?(Map.values(model.states.nodes), &(&1.entries != [])),
      "state actions require source editing"
    )
    |> maybe_add(
      Enum.any?(model.transitions, &(not simple_transition?(&1))),
      "transition guards, priorities, reentry, or actions require source editing"
    )
  end

  defp simple_transition?(%TransitionEdge{} = transition) do
    family_supported? =
      case normalize_trigger(transition.trigger) do
        {family, name} when family in [:request, :event] and is_atom(name) -> true
        _ -> false
      end

    family_supported? and is_nil(transition.guard) and transition.priority in [nil, 0] and
      transition.reenter? in [nil, false] and default_transition_actions?(transition)
  end

  defp default_transition_actions(:request),
    do: [%ActionNode{kind: :reply, args: %{value: :ok}, provenance: nil}]

  defp default_transition_actions(_family), do: []

  defp default_transition_actions?(%TransitionEdge{} = transition) do
    case normalize_trigger(transition.trigger) do
      {:request, _name} ->
        match?(
          [
            %ActionNode{
              kind: :reply,
              args: %{value: :ok}
            }
          ],
          transition.actions
        )

      {_family, _name} ->
        transition.actions == []
    end
  end

  defp normalize_transition_trigger(%{family: family, trigger: trigger})
       when is_binary(family) and is_binary(trigger) do
    {String.to_atom(family), trigger}
  end

  defp boundary_rows(map) do
    map
    |> Map.values()
    |> Enum.sort_by(&atom_name_to_string(&1.name))
    |> Enum.map(fn decl -> %{name: atom_name_to_string(decl.name), meaning: decl.meaning} end)
  end

  defp boundary_projection_rows(map) do
    map
    |> Map.values()
    |> Enum.sort_by(&atom_name_to_string(&1.name))
    |> Enum.map(fn decl ->
      %{
        name: atom_name_to_string(decl.name),
        kind: decl.kind,
        meaning: decl.meaning,
        type: decl.type,
        default: decl.default,
        public?: decl.public?,
        skill?: decl.skill?
      }
    end)
  end

  defp boundary_map(rows, kind, skill?) do
    Map.new(rows, fn row ->
      atom_name = name_atom(row.name)

      {atom_name,
       %BoundaryDecl{
         kind: kind,
         name: atom_name,
         meaning: Map.get(row, :meaning),
         skill?: skill?,
         provenance: nil
       }}
    end)
  end

  defp field_projection_rows(map) do
    map
    |> Map.values()
    |> Enum.sort_by(&atom_name_to_string(&1.name))
    |> Enum.map(fn field ->
      %{
        name: atom_name_to_string(field.name),
        type: field.type,
        default: field.default,
        meaning: field.meaning,
        public?: field.public?
      }
    end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp name_atom(name), do: name |> to_string() |> String.to_atom()
  defp atom_name_to_string(name) when is_atom(name), do: Atom.to_string(name)

  defp module_name_from_model(%MachineModel{module: module, metadata: %{name: name}})
       when is_atom(module) and is_atom(name) do
    prefix =
      module
      |> Module.split()
      |> Enum.drop(-1)

    Module.concat(prefix ++ [Macro.camelize(Atom.to_string(name))])
    |> Module.split()
    |> Enum.join(".")
  end

  defp module_name_from_model(%MachineModel{module: module}) when is_atom(module),
    do: Module.split(module) |> Enum.join(".")

  defp normalize_trigger({family, name}) when family in [:request, :event] and is_atom(name),
    do: {family, name}

  defp normalize_trigger(name) when is_atom(name), do: {:event, name}

  defp normalize_trigger(_other), do: {:event, :event}

  defp normalize_graph_trigger({family, name}) when is_atom(family) and is_atom(name),
    do: {family, name}

  defp normalize_graph_trigger(name) when is_atom(name), do: {:event, name}

  defp normalize_graph_trigger(_other), do: {:event, :event}

  defp format_diagnostic(diagnostic) do
    location =
      case {diagnostic.line, diagnostic.column} do
        {line, column} when is_integer(line) and is_integer(column) -> " (line #{line}:#{column})"
        {line, _} when is_integer(line) -> " (line #{line})"
        _ -> ""
      end

    diagnostic.message <> location
  end

  defp maybe_add(errors, true, message), do: [message | errors]
  defp maybe_add(errors, false, _message), do: errors
end
