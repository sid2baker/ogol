defmodule Ogol.Sequence.Source do
  @moduledoc false

  alias Ogol.Session

  @spec default_model(String.t(), keyword()) :: map()
  def default_model(id \\ "sequence_1", opts \\ []) do
    id = normalize_id(id)

    topology_module_name =
      case Keyword.fetch(opts, :topology_module_name) do
        {:ok, module_name} -> module_name
        :error -> default_topology_module_name()
      end

    %{
      sequence_id: id,
      module_name: "Ogol.Generated.Sequences.#{Macro.camelize(id)}",
      name: id,
      topology_module_name: topology_module_name,
      meaning: "#{humanize_id(id)} sequence",
      invariants: [
        %{
          condition: "Expr.not_expr(Ref.topology(:estop))",
          meaning: "E-stop must remain clear"
        }
      ],
      procedures: [
        %{
          name: "startup",
          meaning: nil,
          steps: [
            %{
              kind: "fail",
              message: "TODO: define startup behavior",
              meaning: "Replace this placeholder"
            }
          ]
        }
      ],
      root_steps: [
        %{kind: "run", procedure: "startup", meaning: nil}
      ]
    }
  end

  @spec default_source(String.t(), keyword()) :: String.t()
  def default_source(id \\ "sequence_1", opts \\ []) do
    id
    |> default_model(opts)
    |> to_source()
  end

  @spec to_source(map()) :: String.t()
  def to_source(model) when is_map(model) do
    module_name = Map.fetch!(model, :module_name)
    name = Map.fetch!(model, :name)
    topology_module_name = Map.fetch!(model, :topology_module_name)

    sequence_sections =
      [
        [
          "    name(:#{name})",
          "    topology(#{topology_module_name})",
          meaning_line(Map.get(model, :meaning))
        ]
        |> Enum.reject(&is_nil/1),
        Enum.map(Map.get(model, :invariants, []), &invariant_line/1),
        Enum.map(Map.get(model, :procedures, []), &proc_block/1),
        Enum.map(Map.get(model, :root_steps, []), &step_line(&1, 2))
      ]
      |> Enum.reject(&(&1 == []))
      |> Enum.map(&Enum.join(&1, "\n"))
      |> Enum.join("\n\n")

    source = """
    defmodule #{module_name} do
      use Ogol.Sequence

      alias Ogol.Sequence.Expr
      alias Ogol.Sequence.Ref

      sequence do
    #{sequence_sections}
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
      {:ok, model}
    else
      {:error, reason} -> {:error, normalize_diagnostics(reason)}
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

  @spec summary(map()) :: String.t()
  def summary(model) when is_map(model) do
    "#{length(model.procedures)} procedures, #{length(model.invariants)} invariants, #{length(model.root_steps)} root steps"
  end

  defp invariant_line(%{condition: condition, meaning: meaning}) do
    args =
      [condition]
      |> maybe_append_option(:meaning, meaning)
      |> Enum.join(", ")

    "    invariant(#{args})"
  end

  defp meaning_line(nil), do: nil
  defp meaning_line(""), do: nil
  defp meaning_line(meaning), do: "    meaning(#{inspect(meaning)})"

  defp proc_block(%{name: name, meaning: meaning, steps: steps}) do
    header =
      case meaning do
        nil -> "proc :#{name} do"
        _ -> "proc :#{name}, meaning: #{inspect(meaning)} do"
      end

    """
        #{header}
    #{Enum.map_join(steps, "\n", &step_line(&1, 3))}
        end
    """
    |> String.trim_trailing()
  end

  defp step_line(%{kind: "do_skill"} = step, indent_level) do
    args =
      [":#{step.machine}", ":#{step.skill}"]
      |> maybe_append_option(:when, Map.get(step, :guard))
      |> maybe_append_option(:timeout, Map.get(step, :timeout_ms))
      |> maybe_append_option(:meaning, Map.get(step, :meaning))
      |> Enum.join(", ")

    indent(indent_level) <> "do_skill(#{args})"
  end

  defp step_line(%{kind: kind} = step, indent_level)
       when kind in ["wait_status", "wait_signal"] do
    args =
      [step.condition]
      |> maybe_append_option(:signal?, kind == "wait_signal")
      |> maybe_append_option(:when, Map.get(step, :guard))
      |> maybe_append_option(:timeout, Map.get(step, :timeout_ms))
      |> maybe_append_option(:fail, Map.get(step, :fail_message))
      |> maybe_append_option(:meaning, Map.get(step, :meaning))
      |> Enum.join(", ")

    indent(indent_level) <> "wait(#{args})"
  end

  defp step_line(%{kind: "run"} = step, indent_level) do
    args =
      [":#{step.procedure}"]
      |> maybe_append_option(:when, Map.get(step, :guard))
      |> maybe_append_option(:meaning, Map.get(step, :meaning))
      |> Enum.join(", ")

    indent(indent_level) <> "run(#{args})"
  end

  defp step_line(%{kind: "repeat", body: body} = step, indent_level) do
    meaning = Map.get(step, :meaning)
    guard = Map.get(step, :guard)

    args =
      []
      |> maybe_append_option(:when, guard)
      |> maybe_append_option(:meaning, meaning)
      |> Enum.join(", ")

    header =
      case args do
        "" -> indent(indent_level) <> "repeat do"
        _ -> indent(indent_level) <> "repeat(#{args}) do"
      end

    [
      header,
      Enum.map_join(body, "\n", &step_line(&1, indent_level + 1)),
      indent(indent_level) <> "end"
    ]
    |> Enum.join("\n")
  end

  defp step_line(%{kind: "fail"} = step, indent_level) do
    args =
      [inspect(step.message)]
      |> maybe_append_option(:meaning, Map.get(step, :meaning))
      |> Enum.join(", ")

    indent(indent_level) <> "fail(#{args})"
  end

  defp maybe_append_option(parts, _key, nil), do: parts
  defp maybe_append_option(parts, _key, false), do: parts
  defp maybe_append_option(parts, key, value), do: parts ++ ["#{key}: #{literal(value)}"]

  defp literal(value) when is_binary(value), do: inspect(value)
  defp literal(value), do: to_string(value)

  defp indent(level), do: String.duplicate("  ", level)

  defp model_from_ast(ast) do
    with {:ok, module_ast, body} <- extract_defmodule(ast),
         :ok <- ensure_sequence_use(body),
         {:ok, section_body} <- sequence_section(body),
         {:ok, sequence_model} <- parse_sequence_section(section_body) do
      {:ok,
       Map.merge(sequence_model, %{
         sequence_id: normalize_id(Atom.to_string(sequence_model.name)),
         module_name: module_name_from_ast(module_ast)
       })}
    end
  end

  defp extract_defmodule({:__block__, _, [single]}), do: extract_defmodule(single)

  defp extract_defmodule({:defmodule, _, [module_ast, [do: body]]}) do
    {:ok, module_ast, body}
  end

  defp extract_defmodule(_other), do: {:error, "sequence source must define exactly one module"}

  defp extract_module_ast({:__block__, _, [single]}), do: extract_module_ast(single)
  defp extract_module_ast({:defmodule, _, [module_ast, _body]}), do: {:ok, module_ast}
  defp extract_module_ast(_other), do: {:error, :module_not_found}

  defp ensure_sequence_use(body) do
    if Enum.any?(top_level_forms(body), &sequence_use?/1) do
      :ok
    else
      {:error, "sequence source must `use Ogol.Sequence`"}
    end
  end

  defp sequence_use?({:use, _, [{:__aliases__, _, [:Ogol, :Sequence]} | _]}), do: true
  defp sequence_use?(_other), do: false

  defp sequence_section(body) do
    case Enum.filter(top_level_forms(body), &match?({:sequence, _, _}, &1)) do
      [{:sequence, _, args}] ->
        {_positional, _opts, section_body} = split_call_args(args)

        if is_nil(section_body) do
          {:error, "sequence source must define a `sequence do ... end` block"}
        else
          {:ok, section_body}
        end

      [] ->
        {:error, "sequence source must define one `sequence` block"}

      _ ->
        {:error, "sequence source defines `sequence` more than once"}
    end
  end

  defp parse_sequence_section(section_body) do
    Enum.reduce_while(
      top_level_forms(section_body),
      {:ok,
       %{
         name: nil,
         topology_module_name: nil,
         meaning: nil,
         invariants: [],
         procedures: [],
         root_steps: []
       }},
      fn form, {:ok, acc} ->
        case parse_sequence_item(form, acc) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, _} = error -> {:halt, error}
        end
      end
    )
    |> case do
      {:ok, %{name: nil}} -> {:error, "sequence block must declare a name"}
      {:ok, %{topology_module_name: nil}} -> {:error, "sequence block must declare a topology"}
      result -> result
    end
  end

  defp parse_sequence_item({:name, _, args}, acc) do
    with {[name_ast], _opts, nil} <- split_call_args(args),
         {:ok, name} <- atom_name(name_ast) do
      {:ok, %{acc | name: name}}
    else
      _ -> {:error, "sequence `name` must be declared as `name(:sequence_name)`"}
    end
  end

  defp parse_sequence_item({:topology, _, args}, acc) do
    with {[module_ast], _opts, nil} <- split_call_args(args),
         {:ok, module_name} <- module_name_opt(module_ast) do
      {:ok, %{acc | topology_module_name: module_name}}
    else
      _ -> {:error, "sequence `topology` must reference one module"}
    end
  end

  defp parse_sequence_item({:meaning, _, args}, acc) do
    with {[meaning], _opts, nil} <- split_call_args(args),
         true <- is_binary(meaning) do
      {:ok, %{acc | meaning: meaning}}
    else
      _ -> {:error, "sequence `meaning` must be a string"}
    end
  end

  defp parse_sequence_item({:invariant, _, args}, acc) do
    with {[condition], opts, nil} <- split_call_args(args),
         :ok <- ensure_only_opts(opts, [:meaning], "invariant"),
         {:ok, meaning} <- string_opt(opts, :meaning) do
      {:ok,
       %{
         acc
         | invariants:
             acc.invariants ++ [%{condition: Macro.to_string(condition), meaning: meaning}]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "invariant uses unsupported source constructs"}
    end
  end

  defp parse_sequence_item({:proc, _, args}, acc) do
    with {[name_ast], opts, body} <- split_call_args(args),
         {:ok, name} <- atom_name(name_ast),
         true <- not is_nil(body),
         :ok <- ensure_only_opts(opts, [:meaning], "proc"),
         {:ok, meaning} <- string_opt(opts, :meaning),
         {:ok, steps} <- parse_steps(body) do
      {:ok,
       %{
         acc
         | procedures:
             acc.procedures ++
               [%{name: Atom.to_string(name), meaning: meaning, steps: steps}]
       }}
    else
      false -> {:error, "proc requires a `do ... end` body"}
      {:error, _} = error -> error
      _ -> {:error, "proc uses unsupported source constructs"}
    end
  end

  defp parse_sequence_item(form, acc) do
    case parse_step(form) do
      {:ok, step} -> {:ok, %{acc | root_steps: acc.root_steps ++ [step]}}
      {:error, _} = error -> error
    end
  end

  defp parse_steps(body) do
    Enum.reduce_while(top_level_forms(body), {:ok, []}, fn form, {:ok, steps} ->
      case parse_step(form) do
        {:ok, step} -> {:cont, {:ok, steps ++ [step]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp parse_step({:do_skill, _, args}) do
    with {[machine_ast, skill_ast], opts, nil} <- split_call_args(args),
         {:ok, machine} <- atom_name(machine_ast),
         {:ok, skill} <- atom_name(skill_ast),
         :ok <- ensure_only_opts(opts, [:when, :timeout, :meaning], "do_skill"),
         {:ok, timeout_ms} <- integer_opt(opts, :timeout),
         {:ok, meaning} <- string_opt(opts, :meaning) do
      {:ok,
       %{
         kind: "do_skill",
         machine: Atom.to_string(machine),
         skill: Atom.to_string(skill),
         guard: expr_opt(opts, :when),
         timeout_ms: timeout_ms,
         meaning: meaning
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "do_skill uses unsupported source constructs"}
    end
  end

  defp parse_step({:wait, _, args}) do
    with {[condition], opts, nil} <- split_call_args(args),
         :ok <- ensure_only_opts(opts, [:timeout, :fail, :signal?, :when, :meaning], "wait"),
         {:ok, timeout_ms} <- integer_opt(opts, :timeout),
         {:ok, fail_message} <- string_opt(opts, :fail),
         {:ok, signal?} <- boolean_opt(opts, :signal?) do
      {:ok,
       %{
         kind: if(signal?, do: "wait_signal", else: "wait_status"),
         condition: Macro.to_string(condition),
         guard: expr_opt(opts, :when),
         timeout_ms: timeout_ms,
         fail_message: fail_message,
         meaning: Keyword.get(opts, :meaning)
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "wait uses unsupported source constructs"}
    end
  end

  defp parse_step({:run, _, args}) do
    with {[procedure_ast], opts, nil} <- split_call_args(args),
         {:ok, procedure} <- atom_name(procedure_ast),
         :ok <- ensure_only_opts(opts, [:when, :meaning], "run"),
         {:ok, meaning} <- string_opt(opts, :meaning) do
      {:ok,
       %{
         kind: "run",
         procedure: Atom.to_string(procedure),
         guard: expr_opt(opts, :when),
         meaning: meaning
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "run uses unsupported source constructs"}
    end
  end

  defp parse_step({:repeat, _, args}) do
    with {[], opts, body} <- split_call_args(args),
         true <- not is_nil(body),
         :ok <- ensure_only_opts(opts, [:when, :meaning], "repeat"),
         {:ok, steps} <- parse_steps(body),
         {:ok, meaning} <- string_opt(opts, :meaning) do
      {:ok,
       %{
         kind: "repeat",
         guard: expr_opt(opts, :when),
         meaning: meaning,
         body: steps
       }}
    else
      false -> {:error, "repeat requires a `do ... end` body"}
      {:error, _} = error -> error
      _ -> {:error, "repeat uses unsupported source constructs"}
    end
  end

  defp parse_step({:fail, _, args}) do
    with {[message], opts, nil} <- split_call_args(args),
         true <- is_binary(message),
         :ok <- ensure_only_opts(opts, [:meaning], "fail"),
         {:ok, meaning} <- string_opt(opts, :meaning) do
      {:ok, %{kind: "fail", message: message, meaning: meaning}}
    else
      false -> {:error, "fail requires a string message"}
      {:error, _} = error -> error
      _ -> {:error, "fail uses unsupported source constructs"}
    end
  end

  defp parse_step(_other), do: {:error, "sequence source uses unsupported step constructs"}

  defp split_call_args(args) when is_list(args) do
    {body, args_without_body, do_opts} =
      case Enum.split(args, -1) do
        {rest, [last]} ->
          if is_list(last) and Keyword.keyword?(last) and Keyword.has_key?(last, :do) do
            {Keyword.get(last, :do), rest, Keyword.delete(last, :do)}
          else
            {nil, args, []}
          end

        _ ->
          {nil, args, []}
      end

    {positional, opts} = trailing_keyword_args(args_without_body)
    {positional, opts ++ do_opts, body}
  end

  defp split_call_args(_other) do
    {[], [], nil}
  end

  defp trailing_keyword_args(args) when is_list(args) do
    case Enum.split(args, -1) do
      {rest, [last]} ->
        if is_list(last) and Keyword.keyword?(last) do
          {rest, last}
        else
          {args, []}
        end

      _ ->
        {args, []}
    end
  end

  defp default_topology_module_name do
    case Session.list_topologies() |> Enum.sort_by(& &1.id) |> List.first() do
      %{model: %{module_name: module_name}} when is_binary(module_name) ->
        module_name

      %{source: source} ->
        case module_from_source(source) do
          {:ok, module} -> Atom.to_string(module) |> String.trim_leading("Elixir.")
          _ -> "Ogol.Generated.Topologies.Topology1"
        end

      _ ->
        "Ogol.Generated.Topologies.Topology1"
    end
  end

  defp ensure_only_opts(opts, allowed, context) do
    extras = opts |> Keyword.keys() |> Enum.uniq() |> Enum.reject(&(&1 in allowed))

    case extras do
      [] ->
        :ok

      _ ->
        {:error,
         "#{context} uses unsupported options: #{Enum.map_join(extras, ", ", &inspect/1)}"}
    end
  end

  defp string_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      other -> {:error, "#{inspect(key)} must be a string, got #{inspect(other)}"}
    end
  end

  defp integer_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      other -> {:error, "#{inspect(key)} must be a non-negative integer, got #{inspect(other)}"}
    end
  end

  defp boolean_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, false}
      value when is_boolean(value) -> {:ok, value}
      other -> {:error, "#{inspect(key)} must be a boolean, got #{inspect(other)}"}
    end
  end

  defp expr_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> nil
      expr -> Macro.to_string(expr)
    end
  end

  defp atom_name({name, _, nil}) when is_atom(name), do: {:ok, name}
  defp atom_name(name) when is_atom(name), do: {:ok, name}
  defp atom_name(other), do: {:error, "expected atom name, got #{Macro.to_string(other)}"}

  defp module_name_opt({:__aliases__, _, parts}), do: {:ok, Enum.join(parts, ".")}

  defp module_name_opt(module) when is_atom(module),
    do: {:ok, Atom.to_string(module) |> String.trim_leading("Elixir.")}

  defp module_name_opt(other),
    do: {:error, "expected module alias, got #{Macro.to_string(other)}"}

  defp module_name_from_ast({:__aliases__, _, parts}), do: Enum.join(parts, ".")

  defp module_name_from_ast(atom) when is_atom(atom),
    do: Atom.to_string(atom) |> String.trim_leading("Elixir.")

  defp module_from_ast!({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_from_ast!(atom) when is_atom(atom), do: atom

  defp top_level_forms({:__block__, _, forms}), do: forms
  defp top_level_forms(form), do: [form]

  defp normalize_id(id) do
    id
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/u, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "sequence"
      normalized -> normalized
    end
  end

  defp humanize_id(id) do
    id
    |> normalize_id()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp normalize_diagnostics(reason) when is_binary(reason), do: [reason]
  defp normalize_diagnostics(reason) when is_list(reason), do: Enum.map(reason, &to_string/1)
  defp normalize_diagnostics(reason), do: [inspect(reason)]
end
