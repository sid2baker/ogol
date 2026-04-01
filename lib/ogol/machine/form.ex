defmodule Ogol.Machine.Form do
  @moduledoc false

  @supported_trigger_families ~w(request event)

  @snake_case_schema_error "must use lowercase snake_case"
  @module_name_schema_error "module name must be a valid Elixir alias"

  @name_schema Zoi.string()
               |> Zoi.trim()
               |> Zoi.to_downcase()
               |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/, error: @snake_case_schema_error)

  @named_row_schema Zoi.map(%{
                      name: @name_schema,
                      meaning: Zoi.string() |> Zoi.trim() |> Zoi.default("")
                    })

  @state_schema Zoi.map(%{
                  name: @name_schema,
                  initial?: Zoi.boolean() |> Zoi.default(false),
                  status: Zoi.string() |> Zoi.trim() |> Zoi.default(""),
                  meaning: Zoi.string() |> Zoi.trim() |> Zoi.default("")
                })

  @transition_schema Zoi.map(%{
                       source: @name_schema,
                       family:
                         Zoi.string()
                         |> Zoi.trim()
                         |> Zoi.to_downcase()
                         |> Zoi.one_of(@supported_trigger_families,
                           error: "transition family must be request or event"
                         ),
                       trigger: @name_schema,
                       destination: @name_schema,
                       meaning: Zoi.string() |> Zoi.trim() |> Zoi.default("")
                     })

  @schema Zoi.map(%{
            machine_id: @name_schema,
            module_name:
              Zoi.string()
              |> Zoi.trim()
              |> Zoi.min(1, error: @module_name_schema_error)
              |> Zoi.regex(~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/,
                error: @module_name_schema_error
              ),
            meaning: Zoi.string() |> Zoi.trim() |> Zoi.default(""),
            requests: Zoi.array(@named_row_schema),
            events: Zoi.array(@named_row_schema),
            commands: Zoi.array(@named_row_schema),
            signals: Zoi.array(@named_row_schema),
            states:
              Zoi.array(@state_schema)
              |> Zoi.min(1, error: "at least one state is required"),
            transitions: Zoi.array(@transition_schema)
          })
          |> Zoi.refine({__MODULE__, :validate_model, []})

  def schema, do: @schema

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
    |> normalize_model()
  end

  def to_form(model) when is_map(model) do
    model = normalize_model(model)

    %{
      "machine_id" => model.machine_id,
      "module_name" => model.module_name,
      "meaning" => model.meaning || "",
      "request_count" => Integer.to_string(length(model.requests)),
      "event_count" => Integer.to_string(length(model.events)),
      "command_count" => Integer.to_string(length(model.commands)),
      "signal_count" => Integer.to_string(length(model.signals)),
      "state_count" => Integer.to_string(length(model.states)),
      "transition_count" => Integer.to_string(length(model.transitions)),
      "requests" => indexed_map(model.requests),
      "events" => indexed_map(model.events),
      "commands" => indexed_map(model.commands),
      "signals" => indexed_map(model.signals),
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

  def cast(params) when is_map(params) do
    params
    |> normalize_form_params()
    |> then(&Zoi.parse(schema(), &1))
    |> case do
      {:ok, parsed} ->
        {:ok, normalize_model(parsed)}

      {:error, errors} ->
        {:error, Enum.map(errors, &format_error/1)}
    end
  end

  def normalize_model(model) when is_map(model) do
    %{
      machine_id:
        model
        |> fetch_string_key(:machine_id, "machine")
        |> normalize_id(),
      module_name:
        model
        |> fetch_string_key(:module_name, "")
        |> normalize_module_name(fetch_string_key(model, :machine_id, "machine")),
      meaning: model |> fetch_string_key(:meaning, "") |> blank_to_nil(),
      requests:
        model
        |> fetch_collection(:requests)
        |> normalize_named_collection(),
      events:
        model
        |> fetch_collection(:events)
        |> normalize_named_collection(),
      commands:
        model
        |> fetch_collection(:commands)
        |> normalize_named_collection(),
      signals:
        model
        |> fetch_collection(:signals)
        |> normalize_named_collection(),
      states:
        model
        |> fetch_collection(:states)
        |> Enum.map(fn row ->
          %{
            name: normalized_name(fetch_string_key(row, :name, "")),
            initial?: truthy?(Map.get(row, :initial?) || Map.get(row, "initial?")),
            status: row |> fetch_string_key(:status, "") |> blank_to_nil(),
            meaning: row |> fetch_string_key(:meaning, "") |> blank_to_nil()
          }
        end)
        |> normalize_initial_state()
        |> Enum.sort_by(fn state -> {not state.initial?, state.name} end),
      transitions:
        model
        |> fetch_collection(:transitions)
        |> Enum.map(fn row ->
          %{
            source: normalized_name(fetch_string_key(row, :source, "")),
            family:
              row
              |> fetch_string_key(:family, "request")
              |> normalize_trigger_family(),
            trigger: normalized_name(fetch_string_key(row, :trigger, "")),
            destination: normalized_name(fetch_string_key(row, :destination, "")),
            meaning: row |> fetch_string_key(:meaning, "") |> blank_to_nil()
          }
        end)
        |> Enum.sort_by(fn transition ->
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

  def validate_model(model, _opts \\ []) do
    state_names = MapSet.new(Enum.map(model.states, & &1.name))

    errors =
      []
      |> maybe_add_duplicate_error(model.requests, "request names must be unique", [:requests])
      |> maybe_add_duplicate_error(model.events, "event names must be unique", [:events])
      |> maybe_add_duplicate_error(model.commands, "command names must be unique", [:commands])
      |> maybe_add_duplicate_error(model.signals, "signal names must be unique", [:signals])
      |> maybe_add_duplicate_error(model.states, "state names must be unique", [:states])
      |> maybe_add_error(
        Enum.count(model.states, & &1.initial?) != 1,
        "choose exactly one initial state",
        [:states]
      )
      |> maybe_add_error(
        Enum.any?(model.transitions, &(not MapSet.member?(state_names, &1.source))),
        "transition sources must reference an existing state",
        [:transitions]
      )
      |> maybe_add_error(
        Enum.any?(model.transitions, &(not MapSet.member?(state_names, &1.destination))),
        "transition destinations must reference an existing state",
        [:transitions]
      )

    if errors == [] do
      :ok
    else
      {:error, Enum.reverse(errors)}
    end
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
    |> normalize_state_input()
    |> normalize_transition_input()
    |> then(fn normalized ->
      machine_id =
        normalized
        |> Map.get("machine_id", "")
        |> normalize_id()

      %{
        machine_id: machine_id,
        module_name: normalize_module_name(Map.get(normalized, "module_name"), machine_id),
        meaning: normalized_text(Map.get(normalized, "meaning")),
        requests: normalize_named_rows(Map.get(normalized, "requests", %{})),
        events: normalize_named_rows(Map.get(normalized, "events", %{})),
        commands: normalize_named_rows(Map.get(normalized, "commands", %{})),
        signals: normalize_named_rows(Map.get(normalized, "signals", %{})),
        states: normalize_state_rows(Map.get(normalized, "states", %{})),
        transitions: normalize_transition_rows(Map.get(normalized, "transitions", %{}))
      }
    end)
  end

  defp fetch_collection(model, key) do
    model
    |> Map.get(key, Map.get(model, to_string(key), []))
    |> List.wrap()
  end

  defp fetch_string_key(map, key, default) do
    case Map.get(map, key, Map.get(map, to_string(key), default)) do
      nil -> default
      value -> to_string(value)
    end
  end

  defp maybe_add_duplicate_error(errors, rows, message, path) do
    maybe_add_error(
      errors,
      duplicate_names?(Enum.map(rows, & &1.name)),
      message,
      path
    )
  end

  defp maybe_add_error(errors, true, message, path) do
    [Zoi.Error.custom_error(path: path, issue: {message, []}) | errors]
  end

  defp maybe_add_error(errors, false, _message, _path), do: errors

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
        meaning: normalized_text(Map.get(row, "meaning"))
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
        status: normalized_text(Map.get(row, "status")),
        meaning: normalized_text(Map.get(row, "meaning"))
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
        meaning: normalized_text(Map.get(row, "meaning"))
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

  defp duplicate_names?(values), do: length(values) != length(Enum.uniq(values))

  defp checkbox_value(true), do: "true"
  defp checkbox_value(_other), do: "false"
  defp checkbox_form_value(true), do: "true"
  defp checkbox_form_value("true"), do: "true"
  defp checkbox_form_value("on"), do: "true"
  defp checkbox_form_value(_other), do: "false"

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("on"), do: true
  defp truthy?(_other), do: false

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

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_error(%Zoi.Error{path: [], message: message}), do: message

  defp format_error(%Zoi.Error{path: path, message: message}) do
    "#{format_path(path)} #{message}"
  end

  defp format_path(path) do
    path
    |> Enum.map(&to_string/1)
    |> Enum.join(".")
  end
end
