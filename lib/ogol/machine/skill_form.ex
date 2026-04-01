defmodule Ogol.Machine.SkillForm do
  @moduledoc false

  alias Ogol.Machine.Skill

  @type field_t :: %{
          name: atom(),
          label: String.t(),
          type: Skill.arg_type(),
          summary: String.t() | nil,
          value: String.t() | boolean()
        }

  @spec cast(Skill.t(), map() | nil) :: {:ok, map()} | {:error, [String.t()]}
  def cast(%Skill{} = skill, params \\ %{}) do
    normalized = normalize_params(skill.args, params || %{})

    case Zoi.parse(schema(skill.args), normalized) do
      {:ok, payload} -> {:ok, payload}
      {:error, errors} -> {:error, Enum.map(errors, &format_error/1)}
    end
  end

  @spec fields(Skill.t()) :: [field_t()]
  def fields(%Skill{} = skill) do
    Enum.map(skill.args, fn arg ->
      %{
        name: arg_name(arg),
        label: humanize_name(arg_name(arg)),
        type: Map.fetch!(arg, :type),
        summary: Map.get(arg, :summary),
        value: default_form_value(arg)
      }
    end)
  end

  defp schema(args) do
    Map.new(args, fn arg ->
      name = arg_name(arg)
      {name, arg_schema(arg)}
    end)
    |> Zoi.map()
  end

  defp arg_schema(%{type: :string} = arg) do
    Zoi.string()
    |> Zoi.trim()
    |> maybe_require_string(arg)
    |> maybe_default(arg)
  end

  defp arg_schema(%{type: :integer} = arg) do
    Zoi.integer(coerce: true)
    |> maybe_default(arg)
  end

  defp arg_schema(%{type: :float} = arg) do
    Zoi.float(coerce: true)
    |> maybe_default(arg)
  end

  defp arg_schema(%{type: :boolean} = arg) do
    Zoi.boolean(coerce: true)
    |> maybe_default(arg)
  end

  defp arg_schema(%{type: {:enum, values}} = arg) when is_list(values) do
    Zoi.string()
    |> Zoi.one_of(values, error: "choose one of #{Enum.join(values, ", ")}")
    |> maybe_default(arg)
  end

  defp maybe_require_string(schema, %{default: default}) when not is_nil(default), do: schema
  defp maybe_require_string(schema, _arg), do: Zoi.min(schema, 1, error: "is required")

  defp maybe_default(schema, %{default: default}), do: Zoi.default(schema, default)
  defp maybe_default(schema, _arg), do: schema

  defp normalize_params(args, params) do
    params = stringify_keys(params)

    Enum.reduce(args, %{}, fn arg, acc ->
      name = arg_name(arg)
      key = Atom.to_string(name)

      cond do
        Map.has_key?(params, key) ->
          Map.put(acc, name, normalize_value(Map.fetch!(arg, :type), Map.get(params, key)))

        Map.has_key?(arg, :default) ->
          Map.put(acc, name, Map.fetch!(arg, :default))

        true ->
          acc
      end
    end)
  end

  defp normalize_value(:boolean, value), do: truthy?(value)

  defp normalize_value(_type, value) when is_binary(value), do: String.trim(value)
  defp normalize_value(_type, value), do: value

  defp default_form_value(%{default: default, type: :boolean}) when not is_nil(default),
    do: default

  defp default_form_value(%{default: default}) when not is_nil(default), do: to_string(default)
  defp default_form_value(%{type: :boolean}), do: false
  defp default_form_value(_arg), do: ""

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp arg_name(%{name: name}) when is_atom(name), do: name

  defp truthy?(value) when value in [true, "true", "on", 1, "1"], do: true
  defp truthy?(_value), do: false

  defp humanize_name(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_error(%Zoi.Error{path: [], message: message}), do: message

  defp format_error(%Zoi.Error{path: path, message: message}) do
    field =
      path
      |> List.last()
      |> to_string()
      |> String.replace("_", " ")

    "#{field} #{message}"
  end
end
