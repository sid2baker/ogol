defmodule Ogol.Driver.Runtime do
  @moduledoc false

  @type driver_definition :: %{
          required(:id) => String.t(),
          required(:label) => String.t(),
          required(:device_kind) => :digital_input | :digital_output,
          required(:vendor_id) => non_neg_integer(),
          required(:product_code) => non_neg_integer(),
          required(:revision) => non_neg_integer() | :any,
          required(:channels) => [
            %{
              required(:name) => atom(),
              optional(:invert?) => boolean(),
              optional(:default) => boolean()
            }
          ]
        }

  def identity(%{vendor_id: vendor_id, product_code: product_code, revision: revision}) do
    %{vendor_id: vendor_id, product_code: product_code, revision: revision}
  end

  def signal_model(definition, _config, _sii_pdo_configs) do
    base =
      case definition.device_kind do
        :digital_output -> 0x1600
        :digital_input -> 0x1A00
      end

    definition.channels
    |> Enum.with_index(base)
    |> Enum.map(fn {%{name: name}, index} -> {name, index} end)
  end

  def encode_signal(%{device_kind: :digital_input}, _signal, _config, _value), do: <<>>

  def encode_signal(definition, signal, _config, value) do
    channel = channel!(definition, signal)
    <<encode_bool(apply_invert(channel, normalize_bool(value)))::8>>
  end

  def decode_signal(%{device_kind: :digital_output}, _signal, _config, _raw), do: nil

  def decode_signal(definition, signal, _config, <<_::7, bit::1>>) do
    channel = channel!(definition, signal)
    apply_invert(channel, bit == 1)
  end

  def decode_signal(definition, signal, _config, _raw) do
    channel = channel!(definition, signal)
    apply_invert(channel, false)
  end

  def init(definition, _config) do
    {:ok, initial_state(definition)}
  end

  def describe(%{device_kind: :digital_output} = definition, _config) do
    %{
      device_type: :digital_output,
      endpoints: endpoint_descriptions(definition, :output),
      commands: [:set_output]
    }
  end

  def describe(%{device_kind: :digital_input} = definition, _config) do
    %{
      device_type: :digital_input,
      endpoints: endpoint_descriptions(definition, :input),
      commands: []
    }
  end

  def project_state(
        %{device_kind: :digital_output} = definition,
        _decoded_inputs,
        prev_state,
        driver_state,
        _config
      ) do
    next_state =
      prev_state ||
        case driver_state do
          state when is_map(state) -> Map.take(state, Enum.map(definition.channels, & &1.name))
          _ -> initial_state(definition)
        end

    {:ok, next_state, ensure_state(definition, driver_state), [], []}
  end

  def project_state(
        %{device_kind: :digital_input} = definition,
        decoded_inputs,
        prev_state,
        driver_state,
        _config
      ) do
    names = Enum.map(definition.channels, & &1.name)

    next_state =
      prev_state
      |> Kernel.||(ensure_state(definition, driver_state))
      |> Map.merge(Map.take(decoded_inputs, names))

    {:ok, next_state, ensure_state(definition, driver_state), [], []}
  end

  def command(%{device_kind: :digital_input}, command, _state, _driver_state, _config) do
    EtherCAT.Driver.unsupported_command(command)
  end

  def command(
        definition,
        %{ref: ref, name: :set_output, args: %{signal: signal, value: value}},
        _state,
        driver_state,
        _config
      )
      when is_boolean(value) do
    channel = channel!(definition, signal)
    next_state = Map.put(ensure_state(definition, driver_state), channel.name, value)

    notices =
      if is_reference(ref) do
        [{:command_completed, ref}]
      else
        []
      end

    {:ok, [{:write, channel.name, value}], next_state, notices}
  rescue
    KeyError -> {:error, :unknown_signal}
  end

  def command(
        definition,
        %{name: :set_output, args: %{signal: signal}},
        _state,
        _driver_state,
        _config
      ) do
    if Enum.any?(definition.channels, &(&1.name == signal)) do
      {:error, :invalid_output_value}
    else
      {:error, :unknown_signal}
    end
  end

  def command(_definition, command, _state, _driver_state, _config) do
    EtherCAT.Driver.unsupported_command(command)
  end

  def initial_state(definition) do
    Map.new(definition.channels, fn channel ->
      {channel.name, Map.get(channel, :default, false)}
    end)
  end

  defp ensure_state(definition, driver_state) when is_map(driver_state) do
    Map.merge(
      initial_state(definition),
      Map.take(driver_state, Enum.map(definition.channels, & &1.name))
    )
  end

  defp ensure_state(definition, _driver_state), do: initial_state(definition)

  defp normalize_bool(value) when value in [true, 1, "true", "1", true], do: true
  defp normalize_bool(_value), do: false

  defp encode_bool(true), do: 1
  defp encode_bool(false), do: 0

  defp apply_invert(channel, value) do
    if Map.get(channel, :invert?, false), do: not value, else: value
  end

  defp channel!(definition, signal) do
    Enum.find(definition.channels, &(&1.name == signal)) ||
      raise KeyError, key: signal, term: definition.channels
  end

  defp endpoint_descriptions(definition, direction) do
    Enum.map(definition.channels, fn channel ->
      %{
        signal: channel.name,
        name: channel.name,
        direction: direction,
        type: :boolean,
        label: humanize_channel(channel.name),
        description: channel_description(definition.device_kind, direction, channel.name)
      }
    end)
  end

  defp humanize_channel(name) do
    name
    |> Atom.to_string()
    |> String.trim_trailing("?")
    |> String.replace("_", " ")
    |> String.replace(~r/(\d+)/, " \\1")
    |> String.trim()
    |> String.capitalize()
  end

  defp channel_description(_device_kind, :output, name),
    do: "#{humanize_channel(name)} output endpoint"

  defp channel_description(_device_kind, :input, name),
    do: "#{humanize_channel(name)} input endpoint"
end
