defmodule Ogol.Studio.TopologyDefinition do
  @moduledoc false

  @supported_strategies ~w(one_for_one one_for_all rest_for_one)
  @supported_restart_policies ~w(permanent temporary transient)
  @supported_observation_kinds ~w(state signal status down)

  alias Ogol.Studio.MachineDefinition

  @spec default_model(String.t()) :: map()
  def default_model(id \\ "packaging_line") do
    id = normalize_id(id)

    %{
      topology_id: id,
      module_name: "Ogol.Generated.Topologies.#{Macro.camelize(id)}",
      root_machine: id,
      strategy: "one_for_one",
      meaning: "#{humanize_id(id)} topology",
      machines: default_machines(id),
      observations: default_observations(id)
    }
    |> canonicalize_model()
  end

  @spec form_from_model(map()) :: map()
  def form_from_model(model) do
    %{
      "topology_id" => model.topology_id,
      "module_name" => model.module_name,
      "root_machine" => model.root_machine,
      "strategy" => model.strategy,
      "meaning" => model.meaning || "",
      "machine_count" => Integer.to_string(length(model.machines)),
      "observation_count" => Integer.to_string(length(model.observations)),
      "machines" =>
        model.machines
        |> Enum.map(fn machine ->
          %{
            "name" => machine.name,
            "module_name" => machine.module_name,
            "restart" => machine.restart,
            "meaning" => machine.meaning || ""
          }
        end)
        |> indexed_map(),
      "observations" =>
        model.observations
        |> Enum.map(fn observation ->
          %{
            "kind" => observation.kind,
            "source" => observation.source,
            "item" => observation.item || "",
            "as" => observation.as,
            "meaning" => observation.meaning || ""
          }
        end)
        |> indexed_map()
    }
  end

  @spec cast_model(map()) :: {:ok, map()} | {:error, [String.t()]}
  def cast_model(params) when is_map(params) do
    params = normalize_form_params(params)

    topology_id =
      params
      |> Map.get("topology_id", "")
      |> normalize_id()

    machines = normalize_machine_rows(Map.get(params, "machines", %{}))
    root_machine = normalize_root_machine(Map.get(params, "root_machine"), machines, topology_id)
    module_name = normalize_topology_module_name(Map.get(params, "module_name"), topology_id)
    strategy = normalize_strategy(Map.get(params, "strategy"))
    meaning = blank_to_nil(Map.get(params, "meaning"))
    observations = normalize_observation_rows(Map.get(params, "observations", %{}))

    errors =
      []
      |> validate_snake_case(topology_id, "topology id")
      |> validate_module_name(module_name)
      |> validate_strategy(strategy)
      |> validate_machines(machines)
      |> validate_root_machine(root_machine, machines)
      |> validate_observations(observations, machines)

    if errors == [] do
      {:ok,
       %{
         topology_id: topology_id,
         module_name: module_name,
         root_machine: root_machine,
         strategy: strategy,
         meaning: meaning,
         machines: machines,
         observations: observations
       }
       |> canonicalize_model()}
    else
      {:error, errors}
    end
  end

  @spec to_source(map()) :: String.t()
  def to_source(model) when is_map(model) do
    model = canonicalize_model(model)

    source = """
    defmodule #{model.module_name} do
      use Ogol.Topology

      topology do
        root(:#{model.root_machine})
        strategy(:#{model.strategy})
    #{meaning_line(model.meaning)}      end

      machines do
    #{Enum.map_join(model.machines, "\n", &machine_line/1)}
      end

      observations do
    #{Enum.map_join(model.observations, "\n", &observation_line/1)}
      end
    end
    """

    source
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  @spec from_source(String.t()) :: {:ok, map()} | {:error, [String.t()]}
  def from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, model} <- model_from_ast(ast) do
      {:ok, canonicalize_model(model)}
    else
      {:error, reason} -> {:error, List.wrap(reason)}
    end
  end

  def module_from_name!(module_name), do: MachineDefinition.module_from_name!(module_name)

  def summary(model) when is_map(model) do
    "#{length(model.machines)} machines, #{length(model.observations)} observations"
  end

  defp model_from_ast(ast) do
    with {:ok, module_ast, body} <- extract_defmodule(ast),
         :ok <- ensure_topology_use(body),
         {:ok, topology_model} <- parse_topology_section(body),
         {:ok, machines} <- parse_machines_section(body),
         {:ok, observations} <- parse_observations_section(body),
         :ok <- ensure_supported_top_level_forms(body) do
      module_name = module_name_from_ast(module_ast)

      {:ok,
       %{
         topology_id: topology_id_from_module_name(module_name),
         module_name: module_name,
         root_machine: atom_name_to_string(topology_model.root),
         strategy: Atom.to_string(topology_model.strategy || :one_for_one),
         meaning: topology_model.meaning,
         machines: machines,
         observations: observations
       }}
    end
  end

  defp extract_defmodule({:__block__, _, [single]}), do: extract_defmodule(single)

  defp extract_defmodule({:defmodule, _, [module_ast, [do: body]]}) do
    {:ok, module_ast, body}
  end

  defp extract_defmodule(_other), do: {:error, "topology source must define exactly one module"}

  defp ensure_topology_use(body) do
    if Enum.any?(top_level_forms(body), &topology_use?/1) do
      :ok
    else
      {:error, "topology source must `use Ogol.Topology`"}
    end
  end

  defp topology_use?({:use, _, [{:__aliases__, _, [:Ogol, :Topology]} | _]}), do: true
  defp topology_use?(_other), do: false

  defp parse_topology_section(body) do
    with {:ok, section_body} <- required_section(body, :topology) do
      Enum.reduce_while(top_level_forms(section_body), {:ok, %{root: nil, strategy: :one_for_one, meaning: nil}}, fn
        {:root, _, [root]}, {:ok, acc} ->
          case atom_name(root) do
            {:ok, name} -> {:cont, {:ok, %{acc | root: name}}}
            {:error, message} -> {:halt, {:error, message}}
          end

        {:strategy, _, [strategy]}, {:ok, acc} ->
          case atom_name(strategy) do
            {:ok, value} -> {:cont, {:ok, %{acc | strategy: value}}}
            {:error, message} -> {:halt, {:error, message}}
          end

        {:meaning, _, [meaning]}, {:ok, acc} when is_binary(meaning) ->
          {:cont, {:ok, %{acc | meaning: meaning}}}

        _form, _acc ->
          {:halt, {:error, "topology section uses unsupported source constructs"}}
      end)
      |> case do
        {:ok, %{root: nil}} -> {:error, "topology section must declare a root machine"}
        result -> result
      end
    end
  end

  defp parse_machines_section(body) do
    with {:ok, section_body} <- required_section(body, :machines) do
      section_body
      |> top_level_forms()
      |> Enum.reduce_while({:ok, []}, fn form, {:ok, machines} ->
        case parse_machine(form) do
          {:ok, machine} -> {:cont, {:ok, machines ++ [machine]}}
          {:error, message} -> {:halt, {:error, message}}
        end
      end)
      |> case do
        {:ok, []} -> {:error, "topology must declare at least one machine"}
        other -> other
      end
    end
  end

  defp parse_machine({:machine, _, [name_ast, module_ast]}) do
    parse_machine({:machine, [], [name_ast, module_ast, []]})
  end

  defp parse_machine({:machine, _, [name_ast, module_ast, opts_ast]}) do
    with {:ok, name} <- atom_name(name_ast),
         {:ok, opts} <- keyword_opts(opts_ast),
         :ok <- ensure_only_opts(opts, [:restart, :meaning], "machine"),
         {:ok, restart} <- restart_opt(opts),
         {:ok, meaning} <- string_opt(opts, :meaning),
         {:ok, module_name} <- module_name_opt(module_ast) do
      {:ok,
       %{
         name: atom_name_to_string(name),
         module_name: module_name,
         restart: Atom.to_string(restart),
         meaning: meaning
       }}
    end
  end

  defp parse_machine(_other), do: {:error, "machines section uses unsupported source constructs"}

  defp parse_observations_section(body) do
    case optional_section(body, :observations) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, section_body} ->
        Enum.reduce_while(top_level_forms(section_body), {:ok, []}, fn form, {:ok, observations} ->
          case parse_observation(form) do
            {:ok, observation} -> {:cont, {:ok, observations ++ [observation]}}
            {:error, message} -> {:halt, {:error, message}}
          end
        end)

      {:error, message} ->
        {:error, message}
    end
  end

  defp parse_observation({:observe_state, _, [source_ast, item_ast, opts_ast]}) do
    parse_observation_kind("state", source_ast, item_ast, opts_ast)
  end

  defp parse_observation({:observe_signal, _, [source_ast, item_ast, opts_ast]}) do
    parse_observation_kind("signal", source_ast, item_ast, opts_ast)
  end

  defp parse_observation({:observe_status, _, [source_ast, item_ast, opts_ast]}) do
    parse_observation_kind("status", source_ast, item_ast, opts_ast)
  end

  defp parse_observation({:observe_down, _, [source_ast, opts_ast]}) do
    with {:ok, source} <- atom_name(source_ast),
         {:ok, opts} <- keyword_opts(opts_ast),
         :ok <- ensure_only_opts(opts, [:as, :meaning], "observe_down"),
         {:ok, as_name} <- atom_opt(opts, :as),
         {:ok, meaning} <- string_opt(opts, :meaning) do
      {:ok,
       %{
         kind: "down",
         source: atom_name_to_string(source),
         item: nil,
         as: atom_name_to_string(as_name),
         meaning: meaning
       }}
    end
  end

  defp parse_observation(_other), do: {:error, "observations section uses unsupported source constructs"}

  defp parse_observation_kind(kind, source_ast, item_ast, opts_ast) do
    with {:ok, source} <- atom_name(source_ast),
         {:ok, item} <- atom_name(item_ast),
         {:ok, opts} <- keyword_opts(opts_ast),
         :ok <- ensure_only_opts(opts, [:as, :meaning], "observe_#{kind}"),
         {:ok, as_name} <- atom_opt(opts, :as),
         {:ok, meaning} <- string_opt(opts, :meaning) do
      {:ok,
       %{
         kind: kind,
         source: atom_name_to_string(source),
         item: atom_name_to_string(item),
         as: atom_name_to_string(as_name),
         meaning: meaning
       }}
    end
  end

  defp required_section(body, name) do
    case section_entries(body, name) do
      [entry] -> {:ok, entry}
      [] -> {:error, "topology source must define a #{name} section"}
      _ -> {:error, "topology source defines #{name} more than once"}
    end
  end

  defp optional_section(body, name) do
    case section_entries(body, name) do
      [entry] -> {:ok, entry}
      [] -> {:ok, nil}
      _ -> {:error, "topology source defines #{name} more than once"}
    end
  end

  defp section_entries(body, name) do
    body
    |> top_level_forms()
    |> Enum.flat_map(fn
      {^name, _, [[do: section_body]]} -> [section_body]
      {^name, _, [do: section_body]} -> [section_body]
      _ -> []
    end)
  end

  defp ensure_supported_top_level_forms(body) do
    unexpected =
      body
      |> top_level_forms()
      |> Enum.reject(fn
        form when is_nil(form) -> true
        {:@, _, _} -> true
        form -> topology_use?(form) or section_form?(form, :topology) or section_form?(form, :machines) or section_form?(form, :observations)
      end)

    if unexpected == [] do
      :ok
    else
      {:error, "topology source contains unsupported top-level constructs"}
    end
  end

  defp section_form?({name, _, [[do: _section_body]]}, name), do: true
  defp section_form?({name, _, [do: _section_body]}, name), do: true
  defp section_form?(_form, _name), do: false

  defp normalize_form_params(params) do
    params
    |> stringify_keys()
    |> ensure_present("topology_id", "packaging_line")
    |> ensure_present("module_name", "")
    |> ensure_present("root_machine", "")
    |> ensure_present("strategy", "one_for_one")
    |> ensure_present("meaning", "")
    |> normalize_machine_input()
    |> normalize_observation_input()
  end

  defp normalize_machine_input(params) do
    topology_id =
      params
      |> Map.get("topology_id", "packaging_line")
      |> normalize_id()

    requested_count =
      params
      |> Map.get("machine_count", "1")
      |> parse_count(1)
      |> max(1)

    entries = Map.get(params, "machines", %{})

    normalized =
      0..(requested_count - 1)
      |> Enum.map(fn index ->
        fallback = default_machine_row(index, topology_id)
        current = entry_at(entries, index, fallback)

        {Integer.to_string(index),
         %{
           "name" => normalized_name(Map.get(current, "name", fallback["name"])),
           "module_name" =>
             normalize_machine_module_name(
               Map.get(current, "module_name", fallback["module_name"]),
               Map.get(current, "name", fallback["name"])
             ),
           "restart" => normalize_restart(Map.get(current, "restart", fallback["restart"])),
           "meaning" => normalized_text(Map.get(current, "meaning", fallback["meaning"]))
         }}
      end)
      |> Map.new()

    params
    |> Map.put("machine_count", Integer.to_string(requested_count))
    |> Map.put("machines", normalized)
  end

  defp normalize_observation_input(params) do
    requested_count =
      params
      |> Map.get("observation_count", "0")
      |> parse_count()

    machine_names =
      params
      |> Map.get("machines", %{})
      |> ordered_rows()
      |> Enum.map(fn row -> normalized_name(Map.get(row, "name")) end)
      |> Enum.reject(&(&1 == ""))

    fallback_source = List.first(machine_names) || "machine_1"
    entries = Map.get(params, "observations", %{})

    normalized =
      indices_for(requested_count)
      |> Enum.map(fn index ->
        fallback = default_observation_row(index, fallback_source)
        current = entry_at(entries, index, fallback)
        kind = normalize_observation_kind(Map.get(current, "kind", fallback["kind"]))

        {Integer.to_string(index),
         %{
           "kind" => kind,
           "source" => normalized_name(Map.get(current, "source", fallback["source"])),
           "item" =>
             if(kind == "down",
               do: "",
               else: normalized_name(Map.get(current, "item", fallback["item"]))
             ),
           "as" => normalized_name(Map.get(current, "as", fallback["as"])),
           "meaning" => normalized_text(Map.get(current, "meaning", fallback["meaning"]))
         }}
      end)
      |> Map.new()

    params
    |> Map.put("observation_count", Integer.to_string(requested_count))
    |> Map.put("observations", normalized)
  end

  defp normalize_machine_rows(rows) do
    rows
    |> ordered_rows()
    |> Enum.map(fn row ->
      name = normalized_name(Map.get(row, "name"))

      %{
        name: name,
        module_name: normalize_machine_module_name(Map.get(row, "module_name"), name),
        restart: normalize_restart(Map.get(row, "restart")),
        meaning: blank_to_nil(Map.get(row, "meaning"))
      }
    end)
  end

  defp normalize_observation_rows(rows) do
    rows
    |> ordered_rows()
    |> Enum.map(fn row ->
      kind = normalize_observation_kind(Map.get(row, "kind"))

      %{
        kind: kind,
        source: normalized_name(Map.get(row, "source")),
        item:
          if(kind == "down",
            do: nil,
            else: blank_to_nil(normalized_name(Map.get(row, "item")))
          ),
        as: normalized_name(Map.get(row, "as")),
        meaning: blank_to_nil(Map.get(row, "meaning"))
      }
    end)
  end

  defp validate_strategy(errors, strategy) do
    maybe_add(
      errors,
      strategy not in @supported_strategies,
      "strategy must be one of #{Enum.join(@supported_strategies, ", ")}"
    )
  end

  defp validate_machines(errors, []), do: ["topology must declare at least one machine" | errors]

  defp validate_machines(errors, machines) do
    errors =
      validate_duplicate_names(errors, machines, "machine")

    Enum.reduce(machines, errors, fn machine, acc ->
      acc
      |> validate_snake_case(machine.name, "machine name")
      |> validate_module_name(machine.module_name)
      |> maybe_add(
        machine.restart not in @supported_restart_policies,
        "machine restart must be one of #{Enum.join(@supported_restart_policies, ", ")}"
      )
    end)
  end

  defp validate_root_machine(errors, root_machine, machines) do
    machine_names = MapSet.new(Enum.map(machines, & &1.name))

    errors
    |> validate_snake_case(root_machine, "root machine")
    |> maybe_add(
      not MapSet.member?(machine_names, root_machine),
      "root machine must reference one of the declared machines"
    )
  end

  defp validate_observations(errors, observations, machines) do
    machine_names = MapSet.new(Enum.map(machines, & &1.name))

    errors =
      validate_duplicate_names(errors, Enum.map(observations, &%{name: &1.as}), "observation alias")

    Enum.reduce(observations, errors, fn observation, acc ->
      acc
      |> maybe_add(
        observation.kind not in @supported_observation_kinds,
        "observation kind must be one of #{Enum.join(@supported_observation_kinds, ", ")}"
      )
      |> validate_snake_case(observation.source, "observation source")
      |> maybe_add(
        not MapSet.member?(machine_names, observation.source),
        "observation source must reference one of the declared machines"
      )
      |> validate_snake_case(observation.as, "observation alias")
      |> maybe_add(
        observation.kind != "down" and blank?(observation.item),
        "observations of kind #{observation.kind} must declare an item"
      )
      |> maybe_add(
        observation.kind != "down" and not blank?(observation.item) and
          not snake_case?(observation.item),
        "observation item must be snake_case"
      )
    end)
  end

  defp validate_duplicate_names(errors, rows, label) do
    duplicates =
      rows
      |> Enum.map(& &1.name)
      |> Enum.reject(&blank?/1)
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)

    Enum.reduce(duplicates, errors, fn {name, _count}, acc ->
      ["#{label} #{inspect(name)} must be unique" | acc]
    end)
  end

  defp validate_snake_case(errors, value, label) do
    if snake_case?(value) do
      errors
    else
      ["#{label} must be snake_case" | errors]
    end
  end

  defp validate_module_name(errors, module_name) do
    if module_name?(module_name) do
      errors
    else
      ["module name must be a valid Elixir alias" | errors]
    end
  end

  defp normalize_id(id) do
    id
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/__+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "topology"
      normalized -> normalized
    end
  end

  defp normalize_root_machine(nil, machines, topology_id), do: default_root_machine(machines, topology_id)
  defp normalize_root_machine("", machines, topology_id), do: default_root_machine(machines, topology_id)
  defp normalize_root_machine(value, _machines, _topology_id), do: normalized_name(value)

  defp default_root_machine([%{name: name} | _], _topology_id), do: name
  defp default_root_machine(_machines, topology_id), do: topology_id

  defp normalize_topology_module_name(value, fallback_id) do
    case value |> to_string() |> String.trim() do
      "" -> "Ogol.Generated.Topologies.#{Macro.camelize(fallback_id || "Topology")}"
      module_name -> module_name
    end
  end

  defp normalize_machine_module_name(value, fallback_id) do
    case value |> to_string() |> String.trim() do
      "" -> "Ogol.Generated.Machines.#{Macro.camelize(fallback_id || "Machine")}"
      module_name -> module_name
    end
  end

  defp normalize_strategy(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "one_for_one"
      other when other in @supported_strategies -> other
      _other -> "one_for_one"
    end
  end

  defp normalize_restart(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "permanent"
      other when other in @supported_restart_policies -> other
      _other -> "permanent"
    end
  end

  defp normalize_observation_kind(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "signal"
      other when other in @supported_observation_kinds -> other
      _other -> "signal"
    end
  end

  defp normalize_name(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]/, "_")
    |> String.replace(~r/__+/, "_")
    |> String.trim("_")
  end

  defp normalized_name(value), do: normalize_name(value)

  defp normalized_text(nil), do: ""
  defp normalized_text(value), do: value |> to_string() |> String.trim()

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank?(value), do: is_nil(blank_to_nil(value))

  defp snake_case?(value) when is_binary(value),
    do: value != "" and String.match?(value, ~r/^[a-z][a-z0-9_]*$/)

  defp snake_case?(_other), do: false

  defp module_name?(value) when is_binary(value) do
    value
    |> String.trim_leading("Elixir.")
    |> String.match?(~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/)
  end

  defp module_name?(_other), do: false

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

  defp parse_count(value, default \\ 0)

  defp parse_count(value, _default) when is_integer(value) and value >= 0, do: min(value, 24)

  defp parse_count(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count >= 0 -> min(count, 24)
      _ -> default
    end
  end

  defp parse_count(_value, default), do: default

  defp indices_for(0), do: []
  defp indices_for(count), do: Enum.to_list(0..(count - 1))

  defp entry_at(entries, index, fallback) do
    Map.get(entries, Integer.to_string(index)) || Map.get(entries, index) || fallback
  end

  defp ordered_rows(rows) do
    rows
    |> Enum.sort_by(fn {key, _value} -> String.to_integer(to_string(key)) end)
    |> Enum.map(&elem(&1, 1))
  end

  defp indexed_map(rows) do
    rows
    |> Enum.with_index()
    |> Map.new(fn {row, index} -> {Integer.to_string(index), row} end)
  end

  defp default_machines("packaging_line") do
    [
      %{
        name: "packaging_line",
        module_name: "Ogol.Generated.Machines.PackagingLine",
        restart: "permanent",
        meaning: "Packaging line coordinator"
      }
    ]
  end

  defp default_machines(id) do
    [
      %{
        name: id,
        module_name: "Ogol.Generated.Machines.#{Macro.camelize(id)}",
        restart: "permanent",
        meaning: "#{humanize_id(id)} coordinator"
      }
    ]
  end

  defp default_observations(_id), do: []

  defp default_machine_row(0, topology_id) do
    %{
      "name" => topology_id,
      "module_name" => "Ogol.Generated.Machines.#{Macro.camelize(topology_id)}",
      "restart" => "permanent",
      "meaning" => "#{humanize_id(topology_id)} coordinator"
    }
  end

  defp default_machine_row(index, _topology_id) do
    name = "machine_#{index + 1}"

    %{
      "name" => name,
      "module_name" => "Ogol.Generated.Machines.#{Macro.camelize(name)}",
      "restart" => "permanent",
      "meaning" => ""
    }
  end

  defp default_observation_row(index, source) do
    %{
      "kind" => "signal",
      "source" => source,
      "item" => "faulted",
      "as" => "observation_#{index + 1}",
      "meaning" => ""
    }
  end

  defp canonicalize_model(model) do
    machines =
      model.machines
      |> Enum.map(fn machine ->
        %{
          name: normalize_name(machine.name),
          module_name: normalize_machine_module_name(machine.module_name, machine.name),
          restart: normalize_restart(machine.restart),
          meaning: blank_to_nil(machine.meaning)
        }
      end)

    root_machine =
      case Enum.find(machines, &(&1.name == model.root_machine)) do
        nil -> machines |> List.first() |> then(&((&1 && &1.name) || normalize_id(model.topology_id)))
        _machine -> normalize_name(model.root_machine)
      end

    observations =
      model.observations
      |> Enum.map(fn observation ->
        kind = normalize_observation_kind(observation.kind)

        %{
          kind: kind,
          source: normalize_name(observation.source),
          item: if(kind == "down", do: nil, else: blank_to_nil(normalize_name(observation.item))),
          as: normalize_name(observation.as),
          meaning: blank_to_nil(observation.meaning)
        }
      end)

    %{
      topology_id: normalize_id(model.topology_id),
      module_name: normalize_topology_module_name(model.module_name, model.topology_id),
      root_machine: root_machine,
      strategy: normalize_strategy(model.strategy),
      meaning: blank_to_nil(model.meaning),
      machines: machines,
      observations: observations
    }
  end

  defp machine_line(machine) do
    opts =
      [restart: ":#{machine.restart}", meaning: quoted_or_nil(machine.meaning)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(", ", fn
        {:restart, value} -> "restart: #{value}"
        {:meaning, value} -> "meaning: #{value}"
      end)

    "    machine(:#{machine.name}, #{machine.module_name}, #{opts})"
  end

  defp observation_line(%{kind: "down"} = observation) do
    opts =
      [as: ":#{observation.as}", meaning: quoted_or_nil(observation.meaning)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(", ", fn
        {:as, value} -> "as: #{value}"
        {:meaning, value} -> "meaning: #{value}"
      end)

    "    observe_down(:#{observation.source}, #{opts})"
  end

  defp observation_line(observation) do
    opts =
      [as: ":#{observation.as}", meaning: quoted_or_nil(observation.meaning)]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(", ", fn
        {:as, value} -> "as: #{value}"
        {:meaning, value} -> "meaning: #{value}"
      end)

    "    observe_#{observation.kind}(:#{observation.source}, :#{observation.item}, #{opts})"
  end

  defp meaning_line(nil), do: ""
  defp meaning_line(meaning), do: "    meaning(#{inspect(meaning)})\n"

  defp quoted_or_nil(nil), do: nil
  defp quoted_or_nil(value), do: inspect(value)

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp top_level_forms({:__block__, _, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp module_name_from_ast(ast), do: ast |> Macro.to_string() |> String.trim()

  defp topology_id_from_module_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
    |> normalize_id()
  end

  defp atom_name(value) when is_atom(value), do: {:ok, value}
  defp atom_name(_other), do: {:error, "topology source must use literal atoms for names"}

  defp atom_name_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp keyword_opts([]), do: {:ok, []}

  defp keyword_opts(ast) do
    with {:ok, value} <- literal_from_ast(ast),
         true <- Keyword.keyword?(value) do
      {:ok, value}
    else
      false -> {:error, "topology source options must stay literal"}
      {:error, _reason} -> {:error, "topology source options must stay literal"}
    end
  end

  defp ensure_only_opts(opts, allowed, label) do
    case Enum.find(opts, fn {key, _value} -> key not in allowed end) do
      nil -> :ok
      {key, _value} -> {:error, "#{label} uses unsupported option #{inspect(key)}"}
    end
  end

  defp restart_opt(opts) do
    case Keyword.get(opts, :restart, :permanent) do
      value when value in [:permanent, :temporary, :transient] -> {:ok, value}
      _other -> {:error, "machine restart must stay a supported literal"}
    end
  end

  defp string_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, blank_to_nil(value)}
      _other -> {:error, "#{inspect(key)} must stay a literal string"}
    end
  end

  defp atom_opt(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, _other} -> {:error, "#{inspect(key)} must stay a literal atom"}
      :error -> {:error, "#{inspect(key)} is required"}
    end
  end

  defp module_name_opt(ast) do
    module_name = module_name_from_ast(ast)

    if module_name?(module_name) do
      {:ok, module_name}
    else
      {:error, "machine modules must stay literal Elixir aliases"}
    end
  end

  defp maybe_add(errors, true, message), do: [message | errors]
  defp maybe_add(errors, false, _message), do: errors

  defp literal_from_ast({:%{}, _, entries}) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key_ast, value_ast}, {:ok, acc} ->
      with {:ok, key} <- literal_from_ast(key_ast),
           {:ok, value} <- literal_from_ast(value_ast) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp literal_from_ast({:{}, _, values}) do
    values
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      error -> error
    end
  end

  defp literal_from_ast(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      error -> error
    end
  end

  defp literal_from_ast({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}

  defp literal_from_ast({:-, _, [value_ast]}) do
    with {:ok, value} <- literal_from_ast(value_ast),
         true <- is_number(value) do
      {:ok, -value}
    else
      false -> {:error, :non_literal}
      {:error, reason} -> {:error, reason}
    end
  end

  defp literal_from_ast(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp literal_from_ast(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_atom(value) or is_nil(value),
       do: {:ok, value}

  defp literal_from_ast(_other), do: {:error, :non_literal}
end
