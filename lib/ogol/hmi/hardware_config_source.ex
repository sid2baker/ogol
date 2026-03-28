defmodule Ogol.HMI.HardwareConfigSource do
  @moduledoc false

  alias Ogol.HMI.HardwareConfig

  @config_attribute :ogol_hardware_config

  @spec canonical_module(HardwareConfig.t()) :: module()
  def canonical_module(%HardwareConfig{id: id}) do
    Module.concat([Ogol, Generated, HardwareConfigs, Macro.camelize(to_string(id))])
  end

  @spec to_source(HardwareConfig.t(), keyword()) :: String.t()
  def to_source(%HardwareConfig{} = config, opts \\ []) do
    module = Keyword.get(opts, :module, canonical_module(config))

    config
    |> to_quoted(module)
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  @spec from_source(String.t()) :: {:ok, HardwareConfig.t()} | :unsupported
  def from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, config_map} <- extract_config_map(ast),
         {:ok, config} <- hardware_config_from_map(config_map) do
      {:ok, config}
    else
      _ -> :unsupported
    end
  end

  defp to_quoted(%HardwareConfig{} = config, module) do
    quote do
      defmodule unquote(alias_ast(module)) do
        def config, do: unquote(Macro.escape(config_literal(config)))
      end
    end
  end

  defp config_literal(%HardwareConfig{} = config) do
    %{
      id: config.id,
      protocol: config.protocol,
      label: config.label,
      spec: config.spec,
      meta: config.meta || %{}
    }
  end

  defp extract_config_map({:defmodule, _, [_module_ast, [do: body]]}) do
    forms = body_forms(body)
    attr_ast = Enum.find_value(forms, &config_attribute_ast/1)

    case Enum.find_value(forms, &config_body_ast/1) do
      nil ->
        :unsupported

      body_ast ->
        body_ast
        |> resolve_config_body(attr_ast)
        |> literal_from_ast()
    end
  end

  defp extract_config_map({:__block__, _, forms}) do
    forms
    |> Enum.filter(&match?({:defmodule, _, _}, &1))
    |> case do
      [form] -> extract_config_map(form)
      _ -> :unsupported
    end
  end

  defp extract_config_map(_other), do: :unsupported

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp config_attribute_ast({:@, _, [{name, _, [value_ast]}]}) when name == @config_attribute,
    do: value_ast

  defp config_attribute_ast(_other), do: nil

  defp config_body_ast({:def, _, [{:config, _, args}, [do: {:__block__, _, [body_ast]}]]})
       when args in [nil, []],
       do: body_ast

  defp config_body_ast({:def, _, [{:config, _, args}, [do: body_ast]]}) when args in [nil, []],
    do: body_ast

  defp config_body_ast(_other), do: nil

  defp resolve_config_body({:@, _, [{name, _, _}]}, attr_ast)
       when name == @config_attribute and not is_nil(attr_ast),
       do: attr_ast

  defp resolve_config_body(body_ast, _attr_ast), do: body_ast

  defp hardware_config_from_map(map) when is_map(map) do
    with {:ok, id} <- fetch_binary(map, :id),
         {:ok, protocol} <- fetch_atom(map, :protocol),
         {:ok, label} <- fetch_binary(map, :label),
         {:ok, spec} <- fetch_map(map, :spec) do
      {:ok,
       %HardwareConfig{
         id: id,
         protocol: protocol,
         label: label,
         spec: spec,
         meta: fetch_optional(map, :meta, %{})
       }}
    end
  end

  defp hardware_config_from_map(_other), do: :unsupported

  defp fetch_binary(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :unsupported
    end
  end

  defp fetch_atom(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_atom(value) -> {:ok, value}
      _ -> :unsupported
    end
  end

  defp fetch_map(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_map(value) -> {:ok, value}
      _ -> :unsupported
    end
  end

  defp fetch_optional(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp alias_ast(module) when is_atom(module) do
    module
    |> Module.split()
    |> Enum.map(&String.to_atom/1)
    |> then(&{:__aliases__, [], &1})
  end

  defp literal_from_ast({:%{}, _, entries}) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key_ast, value_ast}, {:ok, acc} ->
      with {:ok, key} <- literal_from_ast(key_ast),
           {:ok, value} <- literal_from_ast(value_ast) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _ -> {:halt, :unsupported}
      end
    end)
  end

  defp literal_from_ast({:{}, _, values}) do
    values
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      _ -> :unsupported
    end
  end

  defp literal_from_ast({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}

  defp literal_from_ast({:-, _, [value_ast]}) do
    with {:ok, value} <- literal_from_ast(value_ast),
         true <- is_number(value) do
      {:ok, -value}
    else
      _ -> :unsupported
    end
  end

  defp literal_from_ast(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      _ -> :unsupported
    end
  end

  defp literal_from_ast(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_atom(value) or is_nil(value),
       do: {:ok, value}

  defp literal_from_ast(_other), do: :unsupported
end
