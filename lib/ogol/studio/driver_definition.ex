defmodule Ogol.Studio.DriverDefinition do
  @moduledoc false

  @behaviour Ogol.Studio.Definition

  alias Ogol.Studio.DriverParser
  alias Ogol.Studio.DriverPrinter
  alias Ogol.Studio.ZoiDefinition

  @device_kinds [:digital_input, :digital_output]
  @default_vendor_id 0x0000_0002
  @default_product_codes %{
    digital_input: 0x0711_3052,
    digital_output: 0x0AF9_3052
  }
  @channel_schema Zoi.map(%{
                    name:
                      Zoi.string()
                      |> Zoi.trim()
                      |> Zoi.min(1)
                      |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/,
                        error: "channel names must use lowercase snake_case"
                      ),
                    invert?: Zoi.boolean() |> Zoi.default(false),
                    default: Zoi.boolean() |> Zoi.default(false)
                  })
                  |> Zoi.Form.prepare()
  @schema Zoi.map(%{
            id:
              Zoi.string()
              |> Zoi.trim()
              |> Zoi.to_downcase()
              |> Zoi.regex(~r/^[a-z][a-z0-9_]*$/, error: "use lowercase snake_case ids"),
            module_name:
              Zoi.string()
              |> Zoi.trim()
              |> Zoi.min(1),
            label:
              Zoi.string()
              |> Zoi.trim()
              |> Zoi.min(1),
            device_kind:
              Zoi.string()
              |> Zoi.trim()
              |> Zoi.one_of(Enum.map(@device_kinds, &Atom.to_string/1),
                error: "unsupported driver kind"
              ),
            vendor_id:
              Zoi.integer()
              |> Zoi.min(0, error: "vendor_id must be a non-negative integer"),
            product_code:
              Zoi.integer()
              |> Zoi.min(0, error: "product_code must be a non-negative integer"),
            revision:
              Zoi.union([
                Zoi.literal("any"),
                Zoi.integer() |> Zoi.min(0)
              ]),
            channel_count:
              Zoi.integer()
              |> Zoi.min(1, error: "channel count must be between 1 and 32")
              |> Zoi.max(32, error: "channel count must be between 1 and 32"),
            channels:
              Zoi.array(@channel_schema)
              |> Zoi.min(1, error: "at least one channel is required")
              |> Zoi.max(32, error: "channel count must be between 1 and 32")
          })
          |> Zoi.Form.prepare()

  @impl true
  def schema do
    @schema
  end

  @impl true
  def cast_model(params) when is_map(params) do
    params
    |> normalize_form_params()
    |> ZoiDefinition.cast_model(schema())
    |> case do
      {:ok, parsed} ->
        normalize_parsed_model(parsed)

      {:error, errors} ->
        {:error, errors}
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

  defp normalize_form_params(params) do
    params
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> ensure_present("id", "")
    |> ensure_present("module_name", "")
    |> ensure_present("label", "")
    |> ensure_present("device_kind", "digital_output")
    |> ensure_present("vendor_id", Integer.to_string(@default_vendor_id))
    |> ensure_present("product_code", Integer.to_string(@default_product_codes.digital_output))
    |> ensure_present("revision", "any")
    |> normalize_channel_input()
  end

  defp ensure_present(map, key, default) do
    Map.update(map, key, default, fn value ->
      if value in [nil, ""], do: default, else: value
    end)
  end

  defp normalize_channel_input(params) do
    requested_count =
      params
      |> Map.get("channel_count", "0")
      |> parse_channel_count()

    channels_param = Map.get(params, "channels", %{})

    channels =
      0..(requested_count - 1)
      |> Enum.map(fn index ->
        channel_params =
          Map.get(channels_param, Integer.to_string(index)) || Map.get(channels_param, index) ||
            %{}

        %{
          "name" =>
            channel_params
            |> Map.get("name", default_channel_name(index + 1))
            |> to_string()
            |> String.trim()
            |> blank_to_default(default_channel_name(index + 1)),
          "invert?" => channel_params |> Map.get("invert?", false),
          "default" => channel_params |> Map.get("default", false)
        }
      end)

    params
    |> Map.put("channel_count", Integer.to_string(requested_count))
    |> Map.put("channels", channels)
  end

  defp parse_channel_count(value) when is_integer(value) and value > 0, do: min(value, 32)

  defp parse_channel_count(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {count, ""} when count > 0 -> min(count, 32)
      _ -> 1
    end
  end

  defp parse_channel_count(_value), do: 1

  defp normalize_parsed_model(parsed) do
    id = parsed.id
    module_name = normalize_module_name(parsed.module_name, id)

    if module_name =~ ~r/^[A-Z][A-Za-z0-9]*(\.[A-Z][A-Za-z0-9]*)*$/ do
      {:ok,
       %{
         id: id,
         module_name: module_name,
         label: normalize_label(parsed.label, id),
         device_kind: String.to_existing_atom(parsed.device_kind),
         vendor_id: parsed.vendor_id,
         product_code: parsed.product_code,
         revision: normalize_revision_value(parsed.revision),
         channels: normalize_channel_defaults(parsed.channels, parsed.device_kind)
       }}
    else
      {:error, [%{field: :module_name, message: "use a valid Elixir alias"}]}
    end
  rescue
    ArgumentError ->
      {:error, [%{field: :module_name, message: "use a valid Elixir alias"}]}
  end

  defp normalize_module_name(module_name, id) do
    module_name
    |> to_string()
    |> String.trim()
    |> String.trim_leading("Elixir.")
    |> case do
      "" -> "Ogol.Generated.Drivers.#{Macro.camelize(id)}"
      value -> value
    end
  end

  defp normalize_label(label, id) do
    case label |> to_string() |> String.trim() do
      "" -> Macro.camelize(id)
      value -> value
    end
  end

  defp normalize_revision_value("any"), do: :any
  defp normalize_revision_value(value), do: value

  defp normalize_channel_defaults(channels, "digital_output"),
    do: Enum.map(channels, &Map.put(&1, :default, Map.get(&1, :default, false)))

  defp normalize_channel_defaults(channels, _device_kind),
    do: Enum.map(channels, &Map.put(&1, :default, false))

  defp blank_to_default("", fallback), do: fallback
  defp blank_to_default(value, _fallback), do: value
end
