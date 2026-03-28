defmodule Ogol.Studio.DriverDefinition do
  @moduledoc false

  @behaviour Ogol.Studio.Definition

  alias Ogol.Studio.DriverParser
  alias Ogol.Studio.DriverPrinter

  @device_kinds [:digital_input, :digital_output]
  @default_vendor_id 0x0000_0002
  @default_product_codes %{
    digital_input: 0x0711_3052,
    digital_output: 0x0AF9_3052
  }

  @impl true
  def schema do
    %{
      fields: [
        :id,
        :module_name,
        :label,
        :device_kind,
        :vendor_id,
        :product_code,
        :revision,
        :channels
      ]
    }
  end

  @impl true
  def cast_model(params) when is_map(params) do
    with {:ok, id} <- cast_id(Map.get(params, "id") || Map.get(params, :id)),
         {:ok, module_name} <-
           cast_module_name(Map.get(params, "module_name") || Map.get(params, :module_name), id),
         {:ok, label} <- cast_label(Map.get(params, "label") || Map.get(params, :label), id),
         {:ok, device_kind} <-
           cast_device_kind(Map.get(params, "device_kind") || Map.get(params, :device_kind)),
         {:ok, vendor_id} <-
           cast_integer(Map.get(params, "vendor_id") || Map.get(params, :vendor_id), :vendor_id),
         {:ok, product_code} <-
           cast_integer(
             Map.get(params, "product_code") || Map.get(params, :product_code),
             :product_code
           ),
         {:ok, revision} <-
           cast_revision(Map.get(params, "revision") || Map.get(params, :revision)),
         {:ok, channels} <- cast_channels(params, device_kind) do
      {:ok,
       %{
         id: id,
         module_name: module_name,
         label: label,
         device_kind: device_kind,
         vendor_id: vendor_id,
         product_code: product_code,
         revision: revision,
         channels: channels
       }}
    end
  end

  @impl true
  def to_source(module, model) do
    DriverPrinter.print(module, model)
  end

  @impl true
  def from_source(source) do
    DriverParser.parse(source)
  end

  def default_model(id \\ "packaging_outputs") do
    human_label =
      id
      |> String.replace("_", " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)

    %{
      id: id,
      module_name: "Ogol.Generated.Drivers.#{Macro.camelize(id)}",
      label: human_label,
      device_kind: :digital_output,
      vendor_id: @default_vendor_id,
      product_code: @default_product_codes.digital_output,
      revision: :any,
      channels: Enum.map(1..4, &default_channel(&1, :digital_output))
    }
  end

  def form_from_model(model) do
    %{
      "id" => model.id,
      "module_name" => model.module_name,
      "label" => model.label,
      "device_kind" => Atom.to_string(model.device_kind),
      "vendor_id" => Integer.to_string(model.vendor_id),
      "product_code" => Integer.to_string(model.product_code),
      "revision" => revision_to_form(model.revision),
      "channel_count" => Integer.to_string(length(model.channels)),
      "channels" =>
        model.channels
        |> Enum.with_index()
        |> Map.new(fn {channel, index} ->
          {Integer.to_string(index),
           %{
             "name" => channel.name,
             "invert?" => checkbox_value(channel.invert?),
             "default" => checkbox_value(channel.default)
           }}
        end)
    }
  end

  def module_from_name!(module_name) do
    module_name
    |> String.split(".")
    |> Module.concat()
  end

  defp cast_id(id) when is_binary(id) do
    normalized = id |> String.trim() |> String.downcase()

    if normalized =~ ~r/^[a-z][a-z0-9_]*$/ do
      {:ok, normalized}
    else
      {:error, %{field: :id, message: "use lowercase snake_case ids"}}
    end
  end

  defp cast_id(_other), do: {:error, %{field: :id, message: "id is required"}}

  defp cast_module_name(nil, id), do: {:ok, "Ogol.Generated.Drivers.#{Macro.camelize(id)}"}

  defp cast_module_name(module_name, _id) when is_binary(module_name) do
    normalized = module_name |> String.trim() |> String.trim_leading("Elixir.")

    if normalized =~ ~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/ do
      {:ok, normalized}
    else
      {:error, %{field: :module_name, message: "use a valid Elixir alias"}}
    end
  end

  defp cast_module_name(_other, _id),
    do: {:error, %{field: :module_name, message: "module name is required"}}

  defp cast_label(label, id) when is_binary(label) do
    trimmed = String.trim(label)
    {:ok, if(trimmed == "", do: Macro.camelize(id), else: trimmed)}
  end

  defp cast_label(_other, id), do: {:ok, Macro.camelize(id)}

  defp cast_device_kind(kind) when is_binary(kind) do
    kind
    |> String.to_existing_atom()
    |> cast_device_kind()
  rescue
    ArgumentError -> {:error, %{field: :device_kind, message: "unsupported driver kind"}}
  end

  defp cast_device_kind(kind) when kind in @device_kinds, do: {:ok, kind}

  defp cast_device_kind(_other),
    do: {:error, %{field: :device_kind, message: "unsupported driver kind"}}

  defp cast_integer(nil, field), do: {:error, %{field: field, message: "#{field} is required"}}
  defp cast_integer("", field), do: {:error, %{field: field, message: "#{field} is required"}}

  defp cast_integer(value, _field) when is_integer(value) and value >= 0, do: {:ok, value}

  defp cast_integer(value, field) when is_binary(value) do
    trimmed = String.trim(value)

    parsed =
      cond do
        String.starts_with?(trimmed, "0x") ->
          Integer.parse(String.trim_leading(trimmed, "0x"), 16)

        true ->
          Integer.parse(trimmed, 10)
      end

    case parsed do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, %{field: field, message: "#{field} must be a non-negative integer"}}
    end
  end

  defp cast_integer(_other, field),
    do: {:error, %{field: field, message: "#{field} must be a non-negative integer"}}

  defp cast_revision(nil), do: {:ok, :any}
  defp cast_revision(""), do: {:ok, :any}
  defp cast_revision(:any), do: {:ok, :any}
  defp cast_revision("any"), do: {:ok, :any}
  defp cast_revision(value), do: cast_integer(value, :revision)

  defp cast_channels(params, device_kind) do
    requested_count =
      params
      |> Map.get("channel_count", Map.get(params, :channel_count, "0"))
      |> cast_channel_count()

    with {:ok, count} <- requested_count do
      channels_param = Map.get(params, "channels") || Map.get(params, :channels) || %{}

      channels =
        0..(count - 1)
        |> Enum.map(fn index ->
          channel_params =
            Map.get(channels_param, Integer.to_string(index)) || Map.get(channels_param, index) ||
              %{}

          %{
            name:
              channel_params
              |> Map.get("name", default_channel_name(index + 1))
              |> to_string()
              |> String.trim()
              |> blank_to_default(default_channel_name(index + 1)),
            invert?: truthy?(Map.get(channel_params, "invert?")),
            default:
              if(device_kind == :digital_output,
                do: truthy?(Map.get(channel_params, "default")),
                else: false
              )
          }
        end)

      case validate_channel_names(channels) do
        :ok -> {:ok, channels}
        {:error, message} -> {:error, %{field: :channels, message: message}}
      end
    end
  end

  defp cast_channel_count(value) when is_integer(value) and value in 1..32, do: {:ok, value}

  defp cast_channel_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count in 1..32 -> {:ok, count}
      _ -> {:error, %{field: :channel_count, message: "channel count must be between 1 and 32"}}
    end
  end

  defp cast_channel_count(_other),
    do: {:error, %{field: :channel_count, message: "channel count must be between 1 and 32"}}

  defp validate_channel_names(channels) do
    names = Enum.map(channels, & &1.name)

    cond do
      Enum.any?(names, &(not (&1 =~ ~r/^[a-z][a-z0-9_]*$/))) ->
        {:error, "channel names must use lowercase snake_case"}

      Enum.uniq(names) != names ->
        {:error, "channel names must be unique"}

      true ->
        :ok
    end
  end

  defp default_channel(index, device_kind) do
    %{
      name: default_channel_name(index),
      invert?: false,
      default: device_kind == :digital_output and false
    }
  end

  defp default_channel_name(index), do: "ch#{index}"
  defp checkbox_value(true), do: "true"
  defp checkbox_value(_other), do: "false"
  defp revision_to_form(:any), do: "any"
  defp revision_to_form(value) when is_integer(value), do: Integer.to_string(value)
  defp truthy?(value), do: value in [true, "true", "on", "1", 1]
  defp blank_to_default("", fallback), do: fallback
  defp blank_to_default(value, _fallback), do: value
end
