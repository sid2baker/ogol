defmodule Ogol.Studio.DriverParser do
  @moduledoc false

  alias Ogol.Studio.DriverPrinter

  @allowed_attributes [:moduledoc, :behaviour, :ogol_driver_definition]
  @required_defs [:definition] ++ DriverPrinter.delegate_function_names()

  def parse(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, module, forms} <- extract_module(ast),
         {:ok, definition_ast} <- definition_attribute(forms),
         {:ok, definition} <- literal_definition(definition_ast) do
      model = model_from_definition(module, definition)

      if canonical_shape?(forms) do
        {:ok, model}
      else
        {:partial, model,
         [
           "source preserves the driver definition map but no longer matches the supported generated shape"
         ]}
      end
    else
      _ -> :unsupported
    end
  end

  def module_from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source),
         {:ok, module, _forms} <- extract_module(ast) do
      {:ok, module}
    else
      _ -> {:error, :module_not_found}
    end
  end

  defp extract_module({:defmodule, _, [module_ast, [do: body]]}) do
    with {:ok, module} <- module_from_ast(module_ast) do
      {:ok, module, normalize_forms(body)}
    end
  end

  defp extract_module(_other), do: {:error, :unsupported}

  defp module_from_ast({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}
  defp module_from_ast(atom) when is_atom(atom), do: {:ok, atom}
  defp module_from_ast(_other), do: {:error, :unsupported}

  defp normalize_forms({:__block__, _, forms}), do: forms
  defp normalize_forms(form), do: [form]

  defp definition_attribute(forms) do
    Enum.find_value(forms, {:error, :missing_definition}, fn
      {:@, _, [{:ogol_driver_definition, _, [definition_ast]}]} -> {:ok, definition_ast}
      _other -> false
    end)
  end

  defp literal_definition(ast) do
    if Macro.quoted_literal?(ast) do
      {value, _binding} = Code.eval_quoted(ast, [], __ENV__)
      {:ok, value}
    else
      {:error, :non_literal_definition}
    end
  end

  defp canonical_shape?(forms) do
    attributes =
      forms
      |> Enum.filter(fn
        {:@, _, _} -> true
        _ -> false
      end)
      |> Enum.map(fn {:@, _, [{name, _, _}]} -> name end)
      |> Enum.uniq()

    defs =
      forms
      |> Enum.filter(fn
        {:def, _, _} -> true
        _ -> false
      end)
      |> Enum.map(&def_name/1)
      |> Enum.uniq()

    no_extra_attributes? = Enum.all?(attributes, &(&1 in @allowed_attributes))
    no_extra_defs? = Enum.all?(defs, &(&1 in @required_defs))

    no_extra_attributes? and no_extra_defs? and Enum.all?(@required_defs, &(&1 in defs)) and
      :behaviour in attributes and :ogol_driver_definition in attributes
  end

  defp def_name({:def, _, [{name, _, _args}, _body]}), do: name
  defp def_name(_other), do: nil

  defp model_from_definition(module, definition) do
    %{
      id: Map.fetch!(definition, :id),
      module_name: Atom.to_string(module) |> String.trim_leading("Elixir."),
      label: Map.fetch!(definition, :label),
      device_kind: Map.fetch!(definition, :device_kind),
      vendor_id: Map.fetch!(definition, :vendor_id),
      product_code: Map.fetch!(definition, :product_code),
      revision: Map.fetch!(definition, :revision),
      channels:
        definition
        |> Map.fetch!(:channels)
        |> Enum.map(fn channel ->
          %{
            name: channel.name |> Atom.to_string(),
            invert?: Map.get(channel, :invert?, false),
            default: Map.get(channel, :default, false)
          }
        end)
    }
  end
end
