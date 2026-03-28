defmodule Ogol.Studio.DriverPrinter do
  @moduledoc false

  @delegate_functions [
    {:identity,
     "  def identity, do: Ogol.Studio.DriverRuntime.identity(@ogol_driver_definition)\n"},
    {:signal_model,
     "  def signal_model(config, sii_pdo_configs),\n    do: Ogol.Studio.DriverRuntime.signal_model(@ogol_driver_definition, config, sii_pdo_configs)\n"},
    {:encode_signal,
     "  def encode_signal(signal, config, value),\n    do: Ogol.Studio.DriverRuntime.encode_signal(@ogol_driver_definition, signal, config, value)\n"},
    {:decode_signal,
     "  def decode_signal(signal, config, raw),\n    do: Ogol.Studio.DriverRuntime.decode_signal(@ogol_driver_definition, signal, config, raw)\n"},
    {:init,
     "  def init(config), do: Ogol.Studio.DriverRuntime.init(@ogol_driver_definition, config)\n"},
    {:project_state,
     "  def project_state(decoded_inputs, prev_state, driver_state, config),\n    do: Ogol.Studio.DriverRuntime.project_state(@ogol_driver_definition, decoded_inputs, prev_state, driver_state, config)\n"},
    {:command,
     "  def command(command, projected_state, driver_state, config),\n    do: Ogol.Studio.DriverRuntime.command(@ogol_driver_definition, command, projected_state, driver_state, config)\n"},
    {:describe,
     "  def describe(config), do: Ogol.Studio.DriverRuntime.describe(@ogol_driver_definition, config)\n"}
  ]

  def print(module, model) when is_atom(module) and is_map(model) do
    [
      "defmodule ",
      inspect(module),
      " do\n",
      "  @moduledoc ",
      inspect("Generated EtherCAT driver for #{model.label}."),
      "\n",
      "  @behaviour EtherCAT.Driver\n\n",
      "  @ogol_driver_definition ",
      definition_literal(model),
      "\n\n",
      "  def definition, do: @ogol_driver_definition\n\n",
      Enum.map(@delegate_functions, &elem(&1, 1)),
      "end\n"
    ]
    |> IO.iodata_to_binary()
  end

  def definition_literal(model) do
    inspect(definition_map(model), pretty: true, limit: :infinity, width: 98)
  end

  def definition_map(model) do
    %{
      id: model.id,
      label: model.label,
      device_kind: model.device_kind,
      vendor_id: model.vendor_id,
      product_code: model.product_code,
      revision: model.revision,
      channels:
        Enum.map(model.channels, fn channel ->
          %{
            name: String.to_atom(channel.name),
            invert?: Map.get(channel, :invert?, false),
            default: Map.get(channel, :default, false)
          }
        end)
    }
  end

  def delegate_function_names do
    Enum.map(@delegate_functions, &elem(&1, 0))
  end
end
