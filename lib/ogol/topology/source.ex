defmodule Ogol.Topology.Source do
  @moduledoc false

  @supported_strategies ~w(one_for_one one_for_all rest_for_one)
  @supported_restart_policies ~w(permanent temporary transient)

  alias Ogol.Machine.Source, as: MachineSource

  @spec default_model(String.t()) :: map()
  def default_model(id \\ "packaging_line") do
    id = normalize_id(id)

    %{
      topology_id: id,
      module_name: "Ogol.Generated.Topologies.#{Macro.camelize(id)}",
      strategy: "one_for_one",
      meaning: "#{humanize_id(id)} topology",
      machines: default_machines(id)
    }
    |> canonicalize_model()
  end

  @spec form_from_model(map()) :: map()
  def form_from_model(model) do
    %{
      "topology_id" => model.topology_id,
      "module_name" => model.module_name,
      "strategy" => model.strategy,
      "meaning" => model.meaning || "",
      "machine_count" => Integer.to_string(length(model.machines)),
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
    module_name = normalize_topology_module_name(Map.get(params, "module_name"), topology_id)
    strategy = normalize_strategy(Map.get(params, "strategy"))
    meaning = blank_to_nil(Map.get(params, "meaning"))

    errors =
      []
      |> validate_snake_case(topology_id, "topology id")
      |> validate_module_name(module_name)
      |> validate_strategy(strategy)
      |> validate_machines(machines)

    if errors == [] do
      {:ok,
       %{
         topology_id: topology_id,
         module_name: module_name,
         strategy: strategy,
         meaning: meaning,
         machines: machines
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
        strategy(:#{model.strategy})
    #{meaning_line(model.meaning)}      end

      machines do
    #{Enum.map_join(model.machines, "\n", &machine_line/1)}
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
      {:error, reason} -> {:error, normalize_diagnostics(reason)}
    end
  end

  @spec module_from_source(String.t()) :: {:ok, module()} | {:error, :module_not_found}
  def module_from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, module_ast, _body} <- extract_defmodule(ast) do
      {:ok, module_from_ast!(module_ast)}
    else
      _ -> {:error, :module_not_found}
    end
  end

  def module_from_name!(module_name), do: MachineSource.module_from_name!(module_name)

  def summary(model) when is_map(model) do
    "#{length(model.machines)} machines"
  end

  defp model_from_ast(ast) do
    with {:ok, module_ast, body} <- extract_defmodule(ast),
         :ok <- ensure_topology_use(body),
         {:ok, topology_model} <- parse_topology_section(body),
         {:ok, machines} <- parse_machines_section(body),
         :ok <- ensure_supported_top_level_forms(body) do
      module_name = module_name_from_ast(module_ast)

      {:ok,
       %{
         topology_id: topology_id_from_module_name(module_name),
         module_name: module_name,
         strategy: Atom.to_string(topology_model.strategy || :one_for_one),
         meaning: topology_model.meaning,
         machines: machines
       }}
    end
  end

  defp extract_defmodule({:__block__, _, [single]}), do: extract_defmodule(single)

  defp extract_defmodule({:defmodule, _, [module_ast, [do: body]]}) do
    {:ok, module_ast, body}
  end

  defp extract_defmodule(_other), do: {:error, "topology source must define exactly one module"}

  defp module_from_ast!({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_from_ast!(atom) when is_atom(atom), do: atom

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
      Enum.reduce_while(
        top_level_forms(section_body),
        {:ok, %{strategy: :one_for_one, meaning: nil}},
        fn
          {:strategy, _, [strategy]}, {:ok, acc} ->
            case atom_name(strategy) do
              {:ok, value} -> {:cont, {:ok, %{acc | strategy: value}}}
              {:error, message} -> {:halt, {:error, message}}
            end

          {:meaning, _, [meaning]}, {:ok, acc} when is_binary(meaning) ->
            {:cont, {:ok, %{acc | meaning: meaning}}}

          _form, _acc ->
            {:halt, {:error, "topology section uses unsupported source constructs"}}
        end
      )
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
         {:ok, module_name} <- module_name(module_ast) do
      {:ok,
       %{
         name: atom_name_to_string(name),
         module_name: module_name,
         restart: Atom.to_string(restart),
         meaning: Keyword.get(opts, :meaning)
       }}
    end
  end

  defp parse_machine(_other), do: {:error, "machines section uses unsupported source constructs"}

  defp ensure_supported_top_level_forms(body) do
    unsupported? =
      body
      |> top_level_forms()
      |> Enum.any?(fn
        {:use, _, _} -> false
        {:topology, _, _} -> false
        {:machines, _, _} -> false
        _other -> true
      end)

    if unsupported? do
      {:error, "topology source must only define `use`, `topology`, and `machines` at the top level"}
    else
      :ok
    end
  end

  defp required_section(body, name) do
    case Enum.find(top_level_forms(body), &match?({^name, _, _}, &1)) do
      {^name, _, args} ->
        case split_do_args(args) do
          {:ok, _prefix, section_body} -> {:ok, section_body}
          :error -> {:error, "#{name} section uses unsupported source constructs"}
        end

      nil ->
        {:error, "topology source must define a #{name} section"}
    end
  end

  defp split_do_args(args) when is_list(args) do
    {prefix, suffix} = Enum.split_while(args, &(not match?([do: _], &1)))

    case suffix do
      [[do: body]] -> {:ok, prefix, body}
      _other -> :error
    end
  end

  defp top_level_forms({:__block__, _, forms}), do: forms
  defp top_level_forms(nil), do: []
  defp top_level_forms(form), do: [form]

  defp atom_name({name, _, context}) when is_atom(name) and is_atom(context), do: {:ok, name}
  defp atom_name(atom) when is_atom(atom), do: {:ok, atom}
  defp atom_name(_other), do: {:error, "topology source requires atom identifiers"}

  defp keyword_opts(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts}, else: {:error, "topology source uses unsupported keyword options"}
  end

  defp keyword_opts(_other), do: {:error, "topology source uses unsupported keyword options"}

  defp ensure_only_opts(opts, allowed, context) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      [invalid | _] -> {:error, "#{context} option #{inspect(invalid)} is not supported"}
    end
  end

  defp restart_opt(opts) do
    case Keyword.get(opts, :restart, :permanent) do
      restart when restart in [:permanent, :temporary, :transient] -> {:ok, restart}
      other -> {:error, "machine restart #{inspect(other)} is not supported"}
    end
  end

  defp module_name({:__aliases__, _, parts}), do: {:ok, Module.concat(parts) |> inspect()}
  defp module_name(atom) when is_atom(atom), do: {:ok, inspect(atom)}
  defp module_name(_other), do: {:error, "machine declarations require a module alias"}

  defp module_name_from_ast({:__aliases__, _, parts}), do: Module.concat(parts) |> inspect()
  defp module_name_from_ast(atom) when is_atom(atom), do: inspect(atom)

  defp topology_id_from_module_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
    |> Macro.underscore()
  end

  defp normalize_diagnostics(message) when is_binary(message), do: [message]
  defp normalize_diagnostics(other), do: [inspect(other)]

  defp normalize_form_params(params) do
    params
    |> stringify_keys()
    |> ensure_present("topology_id", "topology")
    |> ensure_present("module_name", "")
    |> ensure_present("strategy", "one_for_one")
    |> ensure_present("meaning", "")
    |> normalize_machine_input()
  end

  defp normalize_machine_input(params) do
    requested_count =
      params
      |> Map.get("machine_count", "1")
      |> parse_count(1)

    entries = Map.get(params, "machines", %{})
    topology_id = normalize_id(Map.get(params, "topology_id", "topology"))

    normalized =
      indices_for(requested_count)
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
        meaning: "#{humanize_id(id)} machine"
      }
    ]
  end

  defp default_machine_row(0, topology_id) do
    %{
      "name" => topology_id,
      "module_name" => "Ogol.Generated.Machines.#{Macro.camelize(topology_id)}",
      "restart" => "permanent",
      "meaning" => "#{humanize_id(topology_id)} machine"
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

    %{
      topology_id: normalize_id(model.topology_id),
      module_name: normalize_topology_module_name(model.module_name, model.topology_id),
      strategy: normalize_strategy(model.strategy),
      meaning: blank_to_nil(model.meaning),
      machines: machines
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

  defp meaning_line(nil), do: ""
  defp meaning_line(meaning), do: "    meaning(#{inspect(meaning)})\n"

  defp quoted_or_nil(nil), do: nil
  defp quoted_or_nil(value), do: inspect(value)

  defp maybe_add(errors, true, message), do: [message | errors]
  defp maybe_add(errors, false, _message), do: errors

  defp humanize_id(id) do
    id
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp atom_name_to_string(name) when is_atom(name), do: Atom.to_string(name)
end
