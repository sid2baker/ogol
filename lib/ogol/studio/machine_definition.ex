defmodule Ogol.Studio.MachineDefinition do
  @moduledoc false

  alias Ogol.Authoring.MachineModel
  alias Ogol.Authoring.MachineModel.ActionNode
  alias Ogol.Authoring.MachineModel.BoundaryDecl
  alias Ogol.Authoring.MachineModel.DependencyDecl
  alias Ogol.Authoring.MachineModel.StateNode
  alias Ogol.Authoring.MachineModel.TransitionEdge
  alias Ogol.Authoring.{MachinePrinter, MachineSource}

  @supported_trigger_families ~w(request event)

  @spec default_model(String.t()) :: map()
  def default_model(id \\ "packaging_line") do
    id = normalize_id(id)

    %{
      machine_id: id,
      module_name: "Ogol.Generated.Machines.#{Macro.camelize(id)}",
      meaning: "#{humanize_id(id)} coordinator",
      requests: [%{name: "start"}, %{name: "stop"}, %{name: "reset"}],
      events: [],
      commands: [],
      signals: [%{name: "started"}, %{name: "stopped"}, %{name: "faulted"}],
      dependencies: [],
      states: [
        %{name: "idle", initial?: true, status: "Idle", meaning: nil},
        %{name: "running", initial?: false, status: "Running", meaning: nil},
        %{name: "faulted", initial?: false, status: "Faulted", meaning: nil}
      ],
      transitions: [
        %{
          source: "idle",
          family: "request",
          trigger: "start",
          destination: "running",
          meaning: nil
        },
        %{
          source: "running",
          family: "request",
          trigger: "stop",
          destination: "idle",
          meaning: nil
        },
        %{
          source: "faulted",
          family: "request",
          trigger: "reset",
          destination: "idle",
          meaning: nil
        }
      ]
    }
    |> canonicalize_model()
  end

  @spec form_from_model(map()) :: map()
  def form_from_model(model) do
    events = Map.get(model, :events, [])
    dependencies = Map.get(model, :dependencies, [])

    %{
      "machine_id" => model.machine_id,
      "module_name" => model.module_name,
      "meaning" => model.meaning || "",
      "request_count" => Integer.to_string(length(model.requests)),
      "event_count" => Integer.to_string(length(events)),
      "command_count" => Integer.to_string(length(model.commands)),
      "signal_count" => Integer.to_string(length(model.signals)),
      "dependency_count" => Integer.to_string(length(dependencies)),
      "state_count" => Integer.to_string(length(model.states)),
      "transition_count" => Integer.to_string(length(model.transitions)),
      "requests" => indexed_map(model.requests),
      "events" => indexed_map(events),
      "commands" => indexed_map(model.commands),
      "signals" => indexed_map(model.signals),
      "dependencies" =>
        dependencies
        |> Enum.map(fn dependency ->
          %{
            "name" => dependency.name,
            "meaning" => dependency.meaning || "",
            "skill_count" => Integer.to_string(length(dependency.skills || [])),
            "skills" => indexed_name_map(dependency.skills || []),
            "signal_count" => Integer.to_string(length(dependency.signals || [])),
            "signals" => indexed_name_map(dependency.signals || []),
            "status_count" => Integer.to_string(length(dependency.status || [])),
            "status" => indexed_name_map(dependency.status || [])
          }
        end)
        |> indexed_map(),
      "states" =>
        model.states
        |> Enum.map(fn state ->
          %{
            "name" => state.name,
            "initial?" => checkbox_value(state.initial?),
            "status" => state.status || "",
            "meaning" => state.meaning || ""
          }
        end)
        |> indexed_map(),
      "transitions" =>
        model.transitions
        |> Enum.map(fn transition ->
          %{
            "source" => transition.source,
            "family" => transition.family,
            "trigger" => transition.trigger,
            "destination" => transition.destination,
            "meaning" => transition.meaning || ""
          }
        end)
        |> indexed_map()
    }
  end

  @spec cast_model(map()) :: {:ok, map()} | {:error, [String.t()]}
  def cast_model(params) when is_map(params) do
    params = normalize_form_params(params)

    machine_id =
      params
      |> Map.get("machine_id", "")
      |> normalize_id()

    module_name = normalize_module_name(Map.get(params, "module_name"), machine_id)
    meaning = blank_to_nil(Map.get(params, "meaning"))
    requests = normalize_named_rows(Map.get(params, "requests", %{}))
    events = normalize_named_rows(Map.get(params, "events", %{}))
    commands = normalize_named_rows(Map.get(params, "commands", %{}))
    signals = normalize_named_rows(Map.get(params, "signals", %{}))
    dependencies = normalize_dependency_rows(Map.get(params, "dependencies", %{}))
    states = normalize_state_rows(Map.get(params, "states", %{}))
    transitions = normalize_transition_rows(Map.get(params, "transitions", %{}))

    errors =
      []
      |> validate_snake_case(machine_id, "machine id")
      |> validate_module_name(module_name)
      |> validate_named_collection(requests, "request", allow_empty?: true)
      |> validate_named_collection(events, "event", allow_empty?: true)
      |> validate_named_collection(commands, "command", allow_empty?: true)
      |> validate_named_collection(signals, "signal", allow_empty?: true)
      |> validate_dependencies(dependencies)
      |> validate_states(states)
      |> validate_transitions(transitions, states)

    if errors == [] do
      {:ok,
       %{
         machine_id: machine_id,
         module_name: module_name,
         meaning: meaning,
         requests: requests,
         events: events,
         commands: commands,
         signals: signals,
         dependencies: dependencies,
         states: normalize_initial_state(states),
         transitions: transitions
       }
       |> canonicalize_model()}
    else
      {:error, errors}
    end
  end

  @spec to_source(map()) :: String.t()
  def to_source(model) when is_map(model) do
    model
    |> canonicalize_model()
    |> to_machine_model()
    |> MachinePrinter.print()
  end

  @spec from_source(String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def from_source(source) when is_binary(source) do
    case MachineSource.load_model_source(source) do
      {:ok, %MachineModel{} = model} ->
        case unsupported_features(model) do
          [] -> {:ok, from_machine_model(model)}
          diagnostics -> {:error, diagnostics}
        end

      {:error, artifact} ->
        {:error, Enum.map(artifact.diagnostics, &format_diagnostic/1)}
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
    dependencies = Map.get(model, :dependencies, [])

    "#{length(model.states)} states, #{length(model.transitions)} transitions, #{length(dependencies)} deps"
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
      dependencies: dependency_map(Map.get(model, :dependencies, [])),
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
      dependencies: dependency_rows(model.dependencies),
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

  defp dependency_rows(map) do
    map
    |> Map.values()
    |> Enum.sort_by(&atom_name_to_string(&1.name))
    |> Enum.map(fn decl ->
      %{
        name: atom_name_to_string(decl.name),
        meaning: decl.meaning,
        skills: Enum.map(decl.skills || [], &atom_name_to_string/1),
        signals: Enum.map(decl.signals || [], &atom_name_to_string/1),
        status: Enum.map(decl.status || [], &atom_name_to_string/1)
      }
    end)
  end

  defp dependency_map(rows) do
    Map.new(rows, fn row ->
      atom_name = name_atom(row.name)

      {atom_name,
       %DependencyDecl{
         name: atom_name,
         meaning: Map.get(row, :meaning),
         skills: Enum.map(Map.get(row, :skills, []), &name_atom/1),
         signals: Enum.map(Map.get(row, :signals, []), &name_atom/1),
         status: Enum.map(Map.get(row, :status, []), &name_atom/1),
         provenance: nil
       }}
    end)
  end

  defp normalize_form_params(params) do
    params
    |> stringify_keys()
    |> ensure_present("machine_id", "packaging_line")
    |> ensure_present("module_name", "")
    |> ensure_present("meaning", "")
    |> normalize_named_input("requests", "request_count", "request")
    |> normalize_named_input("events", "event_count", "event")
    |> normalize_named_input("commands", "command_count", "command")
    |> normalize_named_input("signals", "signal_count", "signal")
    |> normalize_dependency_input()
    |> normalize_state_input()
    |> normalize_transition_input()
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp ensure_present(map, key, default) do
    Map.update(map, key, default, fn value ->
      case to_string(value) |> String.trim() do
        "" -> default
        trimmed -> trimmed
      end
    end)
  end

  defp normalize_named_input(params, key, count_key, default_prefix) do
    requested_count =
      params
      |> Map.get(count_key, "0")
      |> parse_count()

    entries = Map.get(params, key, %{})

    normalized =
      indices_for(requested_count)
      |> Enum.map(fn index ->
        fallback = %{"name" => "#{default_prefix}_#{index + 1}", "meaning" => ""}
        current = entry_at(entries, index, fallback)

        {Integer.to_string(index),
         %{
           "name" => normalized_name(Map.get(current, "name")),
           "meaning" => normalized_text(Map.get(current, "meaning"))
         }}
      end)
      |> Map.new()

    params
    |> Map.put(count_key, Integer.to_string(requested_count))
    |> Map.put(key, normalized)
  end

  defp normalize_dependency_input(params) do
    requested_count =
      params
      |> Map.get("dependency_count", "0")
      |> parse_count()

    entries = Map.get(params, "dependencies", %{})

    normalized =
      indices_for(requested_count)
      |> Enum.map(fn index ->
        fallback = %{
          "name" => "dependency_#{index + 1}",
          "meaning" => "",
          "skill_count" => "0",
          "skills" => %{},
          "signal_count" => "0",
          "signals" => %{},
          "status_count" => "0",
          "status" => %{}
        }

        current = entry_at(entries, index, fallback)

        {Integer.to_string(index),
         %{
           "name" => normalized_name(Map.get(current, "name", fallback["name"])),
           "meaning" => normalized_text(Map.get(current, "meaning")),
           "skill_count" => normalized_contract_count(current, "skills", "skill_count"),
           "skills" =>
             normalize_contract_input(Map.get(current, "skills"), Map.get(current, "skill_count")),
           "signal_count" => normalized_contract_count(current, "signals", "signal_count"),
           "signals" =>
             normalize_contract_input(
               Map.get(current, "signals"),
               Map.get(current, "signal_count")
             ),
           "status_count" => normalized_contract_count(current, "status", "status_count"),
           "status" =>
             normalize_contract_input(
               Map.get(current, "status"),
               Map.get(current, "status_count")
             )
         }}
      end)
      |> Map.new()

    params
    |> Map.put("dependency_count", Integer.to_string(requested_count))
    |> Map.put("dependencies", normalized)
  end

  defp normalize_state_input(params) do
    requested_count =
      params
      |> Map.get("state_count", "1")
      |> parse_count(1)

    entries = Map.get(params, "states", %{})

    normalized =
      0..(requested_count - 1)
      |> Enum.map(fn index ->
        fallback = %{
          "name" => default_state_name(index),
          "initial?" => checkbox_value(index == 0),
          "status" => "",
          "meaning" => ""
        }

        current = entry_at(entries, index, fallback)

        {Integer.to_string(index),
         %{
           "name" => normalized_name(Map.get(current, "name", default_state_name(index))),
           "initial?" => checkbox_form_value(Map.get(current, "initial?", index == 0)),
           "status" => normalized_text(Map.get(current, "status")),
           "meaning" => normalized_text(Map.get(current, "meaning"))
         }}
      end)
      |> Map.new()

    params
    |> Map.put("state_count", Integer.to_string(requested_count))
    |> Map.put("states", normalized)
  end

  defp normalize_transition_input(params) do
    requested_count =
      params
      |> Map.get("transition_count", "0")
      |> parse_count()

    entries = Map.get(params, "transitions", %{})

    normalized =
      indices_for(requested_count)
      |> Enum.map(fn index ->
        fallback = %{
          "source" => default_transition_source(index),
          "family" => "request",
          "trigger" => default_transition_trigger(index),
          "destination" => default_transition_destination(index),
          "meaning" => ""
        }

        current = entry_at(entries, index, fallback)

        {Integer.to_string(index),
         %{
           "source" => normalized_name(Map.get(current, "source", fallback["source"])),
           "family" => normalize_trigger_family(Map.get(current, "family", "request")),
           "trigger" => normalized_name(Map.get(current, "trigger", fallback["trigger"])),
           "destination" =>
             normalized_name(Map.get(current, "destination", fallback["destination"])),
           "meaning" => normalized_text(Map.get(current, "meaning"))
         }}
      end)
      |> Map.new()

    params
    |> Map.put("transition_count", Integer.to_string(requested_count))
    |> Map.put("transitions", normalized)
  end

  defp normalize_named_rows(rows) do
    rows
    |> ordered_rows()
    |> Enum.map(fn row ->
      %{
        name: normalized_name(Map.get(row, "name")),
        meaning: blank_to_nil(Map.get(row, "meaning"))
      }
    end)
  end

  defp normalize_dependency_rows(rows) do
    rows
    |> ordered_rows()
    |> Enum.map(fn row ->
      %{
        name: normalized_name(Map.get(row, "name")),
        meaning: blank_to_nil(Map.get(row, "meaning")),
        skills: normalize_contract_rows(Map.get(row, "skills")) |> Enum.sort(),
        signals: normalize_contract_rows(Map.get(row, "signals")) |> Enum.sort(),
        status: normalize_contract_rows(Map.get(row, "status")) |> Enum.sort()
      }
    end)
  end

  defp normalize_state_rows(rows) do
    rows
    |> ordered_rows()
    |> Enum.map(fn row ->
      %{
        name: normalized_name(Map.get(row, "name")),
        initial?: checkbox_form_value(Map.get(row, "initial?")) == "true",
        status: blank_to_nil(Map.get(row, "status")),
        meaning: blank_to_nil(Map.get(row, "meaning"))
      }
    end)
  end

  defp normalize_transition_rows(rows) do
    rows
    |> ordered_rows()
    |> Enum.map(fn row ->
      %{
        source: normalized_name(Map.get(row, "source")),
        family: normalize_trigger_family(Map.get(row, "family")),
        trigger: normalized_name(Map.get(row, "trigger")),
        destination: normalized_name(Map.get(row, "destination")),
        meaning: blank_to_nil(Map.get(row, "meaning"))
      }
    end)
  end

  defp ordered_rows(rows) do
    rows
    |> Enum.sort_by(fn {key, _value} -> String.to_integer(to_string(key)) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp entry_at(entries, index, fallback) do
    Map.get(entries, Integer.to_string(index)) || Map.get(entries, index) || fallback
  end

  defp parse_count(value, default \\ 0)

  defp parse_count(value, _default) when is_integer(value) and value >= 0, do: min(value, 16)

  defp parse_count(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count >= 0 -> min(count, 16)
      _ -> default
    end
  end

  defp parse_count(_value, default), do: default

  defp indices_for(0), do: []
  defp indices_for(count), do: Enum.to_list(0..(count - 1))

  defp normalize_id(id) do
    id
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/__+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "machine"
      value -> value
    end
  end

  defp normalize_module_name(nil, id), do: "Ogol.Generated.Machines.#{Macro.camelize(id)}"

  defp normalize_module_name(module_name, id) do
    module_name
    |> to_string()
    |> String.trim()
    |> String.trim_leading("Elixir.")
    |> case do
      "" -> "Ogol.Generated.Machines.#{Macro.camelize(id)}"
      value -> value
    end
  end

  defp normalize_initial_state(states) do
    with true <- Enum.any?(states, & &1.initial?),
         initial_index <- Enum.find_index(states, & &1.initial?) do
      Enum.with_index(states)
      |> Enum.map(fn {state, index} -> %{state | initial?: index == initial_index} end)
    else
      _ ->
        Enum.with_index(states)
        |> Enum.map(fn {state, index} -> %{state | initial?: index == 0} end)
    end
  end

  defp validate_snake_case(errors, value, label) do
    if value =~ ~r/^[a-z][a-z0-9_]*$/ do
      errors
    else
      ["#{label} must use lowercase snake_case" | errors]
    end
  end

  defp validate_module_name(errors, module_name) do
    if module_name =~ ~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/ do
      errors
    else
      ["module name must be a valid Elixir alias" | errors]
    end
  end

  defp validate_named_collection(errors, rows, label, opts) do
    errors
    |> maybe_add(
      rows == [] and not Keyword.get(opts, :allow_empty?, false),
      "at least one #{label} is required"
    )
    |> maybe_add(
      Enum.any?(rows, &(not valid_name?(&1.name))),
      "#{label} names must use lowercase snake_case"
    )
    |> maybe_add(
      duplicate_names?(Enum.map(rows, & &1.name)),
      "#{label} names must be unique"
    )
  end

  defp validate_dependencies(errors, dependencies) do
    errors
    |> validate_named_collection(dependencies, "dependency", allow_empty?: true)
    |> maybe_add(
      Enum.any?(dependencies, &(not valid_name_list?(&1.skills))),
      "dependency skills must use lowercase snake_case"
    )
    |> maybe_add(
      Enum.any?(dependencies, &(not valid_name_list?(&1.signals))),
      "dependency signals must use lowercase snake_case"
    )
    |> maybe_add(
      Enum.any?(dependencies, &(not valid_name_list?(&1.status))),
      "dependency status entries must use lowercase snake_case"
    )
  end

  defp validate_states(errors, states) do
    errors
    |> maybe_add(states == [], "at least one state is required")
    |> maybe_add(
      Enum.any?(states, &(not valid_name?(&1.name))),
      "state names must use lowercase snake_case"
    )
    |> maybe_add(
      duplicate_names?(Enum.map(states, & &1.name)),
      "state names must be unique"
    )
    |> maybe_add(
      Enum.count(states, & &1.initial?) != 1,
      "choose exactly one initial state"
    )
  end

  defp validate_transitions(errors, transitions, states) do
    state_names = MapSet.new(Enum.map(states, & &1.name))

    errors
    |> maybe_add(
      Enum.any?(transitions, &(not valid_name?(&1.trigger))),
      "transition triggers must use lowercase snake_case"
    )
    |> maybe_add(
      Enum.any?(transitions, &(not MapSet.member?(state_names, &1.source))),
      "transition sources must reference an existing state"
    )
    |> maybe_add(
      Enum.any?(transitions, &(not MapSet.member?(state_names, &1.destination))),
      "transition destinations must reference an existing state"
    )
  end

  defp default_state_name(0), do: "idle"
  defp default_state_name(1), do: "running"
  defp default_state_name(2), do: "faulted"
  defp default_state_name(index), do: "state_#{index + 1}"

  defp default_transition_source(0), do: "idle"
  defp default_transition_source(1), do: "running"
  defp default_transition_source(2), do: "faulted"
  defp default_transition_source(_index), do: "idle"

  defp default_transition_destination(0), do: "running"
  defp default_transition_destination(1), do: "idle"
  defp default_transition_destination(2), do: "idle"
  defp default_transition_destination(_index), do: "idle"

  defp default_transition_trigger(0), do: "start"
  defp default_transition_trigger(1), do: "stop"
  defp default_transition_trigger(2), do: "reset"
  defp default_transition_trigger(index), do: "event_#{index + 1}"

  defp normalize_trigger_family(family) do
    family =
      family
      |> to_string()
      |> String.trim()
      |> String.downcase()

    if family in @supported_trigger_families, do: family, else: "request"
  end

  defp normalized_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/__+/, "_")
    |> String.trim("_")
  end

  defp normalized_text(nil), do: ""
  defp normalized_text(value), do: value |> to_string() |> String.trim()

  defp normalize_name_list(nil), do: []

  defp normalize_name_list(values) when is_list(values) do
    values
    |> Enum.map(&normalized_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_name_list(value) do
    value
    |> to_string()
    |> String.split(",")
    |> Enum.map(&normalized_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp valid_name?(value), do: value =~ ~r/^[a-z][a-z0-9_]*$/
  defp valid_name_list?(values), do: Enum.all?(values, &valid_name?/1)
  defp duplicate_names?(values), do: length(values) != length(Enum.uniq(values))

  defp checkbox_value(true), do: "true"
  defp checkbox_value(_other), do: "false"
  defp checkbox_form_value(true), do: "true"
  defp checkbox_form_value("true"), do: "true"
  defp checkbox_form_value("on"), do: "true"
  defp checkbox_form_value(_other), do: "false"

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp indexed_map(rows) do
    rows
    |> Enum.with_index()
    |> Map.new(fn {row, index} ->
      {Integer.to_string(index), stringify_keys(row)}
    end)
  end

  defp indexed_name_map(names) do
    names
    |> Enum.with_index()
    |> Map.new(fn {name, index} ->
      {Integer.to_string(index), %{"name" => to_string(name)}}
    end)
  end

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
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

  defp canonicalize_model(model) do
    %{
      model
      | requests: normalize_named_collection(model.requests),
        events: normalize_named_collection(Map.get(model, :events, [])),
        commands: normalize_named_collection(model.commands),
        signals: normalize_named_collection(model.signals),
        dependencies: normalize_dependency_collection(Map.get(model, :dependencies, [])),
        states:
          Enum.sort_by(model.states, fn state ->
            {not state.initial?, state.name}
          end),
        transitions:
          Enum.sort_by(model.transitions, fn transition ->
            {
              transition.source,
              transition.destination,
              transition.family,
              transition.trigger,
              transition.meaning
            }
          end)
    }
  end

  defp normalize_named_collection(rows) do
    rows
    |> Enum.map(fn row ->
      %{
        name: normalized_name(Map.get(row, :name) || Map.get(row, "name")),
        meaning: blank_to_nil(Map.get(row, :meaning) || Map.get(row, "meaning"))
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_dependency_collection(rows) do
    rows
    |> Enum.map(fn row ->
      %{
        name: normalized_name(Map.get(row, :name) || Map.get(row, "name")),
        meaning: blank_to_nil(Map.get(row, :meaning) || Map.get(row, "meaning")),
        skills:
          normalize_contract_rows(Map.get(row, :skills) || Map.get(row, "skills")) |> Enum.sort(),
        signals:
          normalize_contract_rows(Map.get(row, :signals) || Map.get(row, "signals"))
          |> Enum.sort(),
        status:
          normalize_contract_rows(Map.get(row, :status) || Map.get(row, "status")) |> Enum.sort()
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_contract_rows(value) do
    value
    |> contract_entries()
    |> ordered_rows()
    |> Enum.map(&normalized_name(Map.get(&1, "name")))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalized_contract_count(row, key, count_key) do
    count =
      row
      |> Map.get(count_key, inferred_contract_count(Map.get(row, key)))
      |> parse_count()

    Integer.to_string(count)
  end

  defp inferred_contract_count(value) do
    value
    |> contract_entries()
    |> map_size()
  end

  defp normalize_contract_input(value, count_value) do
    requested_count =
      count_value
      |> case do
        nil -> inferred_contract_count(value)
        other -> parse_count(other)
      end

    entries = contract_entries(value)

    indices_for(requested_count)
    |> Enum.map(fn index ->
      current = entry_at(entries, index, %{"name" => ""})

      {Integer.to_string(index),
       %{
         "name" => normalized_name(Map.get(current, "name"))
       }}
    end)
    |> Map.new()
  end

  defp contract_entries(value) when is_map(value), do: stringify_keys(value)

  defp contract_entries(value) when is_list(value) do
    value
    |> normalize_name_list()
    |> indexed_name_map()
  end

  defp contract_entries(value) when is_binary(value) do
    value
    |> normalize_name_list()
    |> indexed_name_map()
  end

  defp contract_entries(_value), do: %{}
end
