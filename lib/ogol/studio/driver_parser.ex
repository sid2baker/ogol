defmodule Ogol.Studio.DriverParser do
  @moduledoc false

  alias Ogol.Studio.DriverPrinter

  @allowed_attributes [:moduledoc, :behaviour, :ogol_driver_definition]
  @required_defs [:definition] ++ DriverPrinter.delegate_function_names()

  def parse(source) when is_binary(source) do
    try do
      result =
        with {:ok, ast} <- Code.string_to_quoted(source),
             {:ok, module, forms} <- extract_module(ast),
             {:ok, definition_ast} <- definition_attribute(forms),
             {:ok, definition} <- literal_definition(definition_ast),
             {:ok, model} <- model_from_definition(module, definition) do
          if canonical_shape?(forms) do
            {:ok, model}
          else
            {:partial, model,
             [
               "source preserves the driver definition map but no longer matches the supported generated shape"
             ]}
          end
        end

      case result do
        {:ok, _model} = ok -> ok
        {:partial, _model, _diagnostics} = partial -> partial
        _ -> :unsupported
      end
    rescue
      ArgumentError -> :unsupported
      KeyError -> :unsupported
      Protocol.UndefinedError -> :unsupported
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

  defp model_from_definition(module, definition) when is_map(definition) do
    with {:ok, id} <- fetch_string(definition, :id),
         {:ok, label} <- fetch_string(definition, :label),
         {:ok, device_kind} <- fetch_device_kind(definition, :device_kind),
         {:ok, vendor_id} <- fetch_integer(definition, :vendor_id),
         {:ok, product_code} <- fetch_integer(definition, :product_code),
         {:ok, revision} <- fetch_revision(definition, :revision),
         {:ok, channels} <- fetch_channels(definition, :channels) do
      {:ok,
       %{
         id: id,
         module_name: Atom.to_string(module) |> String.trim_leading("Elixir."),
         label: label,
         device_kind: device_kind,
         vendor_id: vendor_id,
         product_code: product_code,
         revision: revision,
         channels: channels
       }}
    end
  end

  defp model_from_definition(_module, _definition), do: {:error, :unsupported}

  defp fetch_required(definition, key) do
    cond do
      Map.has_key?(definition, key) ->
        {:ok, Map.fetch!(definition, key)}

      Map.has_key?(definition, Atom.to_string(key)) ->
        {:ok, Map.fetch!(definition, Atom.to_string(key))}

      true ->
        {:error, {:missing_key, key}}
    end
  end

  defp fetch_optional(definition, key, default) do
    cond do
      Map.has_key?(definition, key) -> Map.fetch!(definition, key)
      Map.has_key?(definition, Atom.to_string(key)) -> Map.fetch!(definition, Atom.to_string(key))
      true -> default
    end
  end

  defp fetch_string(definition, key) do
    with {:ok, value} <- fetch_required(definition, key),
         {:ok, normalized} <- normalize_string(value) do
      {:ok, normalized}
    end
  end

  defp fetch_integer(definition, key) do
    with {:ok, value} <- fetch_required(definition, key),
         {:ok, normalized} <- normalize_integer(value) do
      {:ok, normalized}
    end
  end

  defp fetch_device_kind(definition, key) do
    with {:ok, value} <- fetch_required(definition, key),
         {:ok, normalized} <- normalize_device_kind(value) do
      {:ok, normalized}
    end
  end

  defp fetch_revision(definition, key) do
    with {:ok, value} <- fetch_required(definition, key),
         {:ok, normalized} <- normalize_revision(value) do
      {:ok, normalized}
    end
  end

  defp fetch_channels(definition, key) do
    with {:ok, channels} <- fetch_required(definition, key),
         {:ok, normalized} <- normalize_channels(channels),
         :ok <- validate_channel_names(normalized) do
      {:ok, normalized}
    else
      _ -> {:error, :unsupported}
    end
  end

  defp normalize_channels(channels) when is_list(channels) do
    normalized =
      Enum.reduce_while(channels, [], fn channel, acc ->
        with true <- is_map(channel),
             {:ok, name} <- fetch_required(channel, :name),
             {:ok, normalized_name} <- normalize_channel_name(name) do
          {:cont,
           acc ++
             [
               %{
                 name: normalized_name,
                 invert?: normalize_boolean(fetch_optional(channel, :invert?, false)),
                 default: normalize_boolean(fetch_optional(channel, :default, false))
               }
             ]}
        else
          _ -> {:halt, :error}
        end
      end)

    case normalized do
      :error -> {:error, :unsupported}
      list -> {:ok, list}
    end
  end

  defp normalize_channels(_other), do: {:error, :unsupported}

  defp normalize_string(value) when is_binary(value), do: {:ok, value}
  defp normalize_string(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_string(_value), do: {:error, :unsupported}

  defp normalize_channel_name(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_channel_name(value) when is_binary(value), do: {:ok, value}
  defp normalize_channel_name(_value), do: {:error, :unsupported}

  defp normalize_device_kind(value) when value in [:digital_input, :digital_output],
    do: {:ok, value}

  defp normalize_device_kind(value) when value in ["digital_input", "digital_output"] do
    {:ok, String.to_existing_atom(value)}
  end

  defp normalize_device_kind(_value), do: {:error, :unsupported}

  defp normalize_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp normalize_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, :unsupported}
    end
  end

  defp normalize_integer(_value), do: {:error, :unsupported}

  defp normalize_revision(:any), do: {:ok, :any}
  defp normalize_revision(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp normalize_revision("any"), do: {:ok, :any}

  defp normalize_revision(value) when is_binary(value) do
    normalize_integer(value)
  end

  defp normalize_revision(_value), do: {:error, :unsupported}

  defp normalize_boolean(value) when value in [true, "true", "on", "1", 1], do: true
  defp normalize_boolean(_value), do: false

  defp validate_channel_names(channels) do
    names = Enum.map(channels, & &1.name)

    cond do
      Enum.any?(names, &(not (&1 =~ ~r/^[a-z][a-z0-9_]*$/))) ->
        {:error, :unsupported}

      Enum.uniq(names) != names ->
        {:error, :unsupported}

      true ->
        :ok
    end
  end
end
