defmodule Ogol.Simulator.Config.Source do
  @moduledoc false

  alias Ogol.Simulator.Config.EtherCAT

  @ethercat_module Ogol.Generated.Simulator.Config.EtherCAT

  @type config_t :: EtherCAT.t()

  @spec canonical_module() :: module()
  def canonical_module, do: @ethercat_module

  @spec canonical_module(String.t() | atom() | config_t()) :: module()
  def canonical_module("ethercat"), do: @ethercat_module
  def canonical_module(:ethercat), do: @ethercat_module
  def canonical_module(%{adapter: :ethercat}), do: @ethercat_module

  @spec artifact_id(config_t()) :: String.t()
  def artifact_id(%{adapter: :ethercat}), do: EtherCAT.artifact_id()

  @spec default_model(String.t() | atom()) :: config_t() | nil
  def default_model("ethercat"), do: EtherCAT.default()
  def default_model(:ethercat), do: EtherCAT.default()
  def default_model(_other), do: nil

  @spec default_source(String.t() | atom()) :: String.t()
  def default_source(id) do
    case default_model(id) do
      %{} = config -> to_source(config)
      nil -> ""
    end
  end

  @spec module_from_source(String.t()) :: {:ok, module()} | {:error, :module_not_found}
  def module_from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, module} <- extract_module(ast) do
      {:ok, module}
    else
      _ -> {:error, :module_not_found}
    end
  end

  @spec to_source(config_t()) :: String.t()
  def to_source(%{adapter: :ethercat} = config) do
    config
    |> to_source_ast(canonical_module(config))
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  @spec from_source(String.t()) :: {:ok, config_t()} | :unsupported
  def from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, opts_ast} <- extract_simulator_opts_ast(ast),
         {:ok, config} <- simulator_config_from_opts_ast(opts_ast) do
      {:ok, config}
    else
      _ -> :unsupported
    end
  end

  defp to_source_ast(%{adapter: :ethercat} = config, module) do
    devices_ast = Enum.map(config.devices, &device_ast/1)

    quote do
      defmodule unquote(module) do
        def simulator_opts do
          [
            devices: unquote(devices_ast),
            backend: unquote(Macro.escape(config.backend)),
            topology: unquote(config.topology)
          ]
        end
      end
    end
  end

  defp device_ast(%{name: name, driver: driver}) do
    quote do
      EtherCAT.Simulator.Slave.from_driver(unquote(driver), name: unquote(name))
    end
  end

  defp extract_simulator_opts_ast({:defmodule, _, [_module_ast, [do: body]]}) do
    body
    |> body_forms()
    |> Enum.find_value(&simulator_opts_body_ast/1)
    |> case do
      nil -> :unsupported
      body_ast -> {:ok, body_ast}
    end
  end

  defp extract_simulator_opts_ast({:__block__, _, forms}) do
    forms
    |> Enum.filter(&match?({:defmodule, _, _}, &1))
    |> case do
      [form] -> extract_simulator_opts_ast(form)
      _ -> :unsupported
    end
  end

  defp extract_simulator_opts_ast(_other), do: :unsupported

  defp simulator_opts_body_ast(
         {:def, _, [{:simulator_opts, _, args}, [do: {:__block__, _, [body_ast]}]]}
       )
       when args in [nil, []],
       do: body_ast

  defp simulator_opts_body_ast({:def, _, [{:simulator_opts, _, args}, [do: body_ast]]})
       when args in [nil, []],
       do: body_ast

  defp simulator_opts_body_ast(_other), do: nil

  defp simulator_config_from_opts_ast(opts_ast) when is_list(opts_ast) do
    with {:ok, devices_ast} <- fetch_keyword_ast(opts_ast, :devices),
         {:ok, backend_ast} <- fetch_keyword_ast(opts_ast, :backend),
         {:ok, topology_ast} <- fetch_keyword_ast(opts_ast, :topology),
         {:ok, devices} <- parse_devices_ast(devices_ast),
         {:ok, backend} <- literal_from_ast(backend_ast),
         {:ok, topology} <- literal_from_ast(topology_ast),
         true <- backend_valid?(backend),
         true <- topology in [:linear, :redundant] do
      {:ok, %{adapter: :ethercat, devices: devices, backend: backend, topology: topology}}
    else
      _ -> :unsupported
    end
  end

  defp simulator_config_from_opts_ast(_other), do: :unsupported

  defp fetch_keyword_ast(keyword, key) when is_list(keyword) do
    case Keyword.fetch(keyword, key) do
      {:ok, value_ast} -> {:ok, value_ast}
      :error -> :unsupported
    end
  end

  defp parse_devices_ast(devices_ast) when is_list(devices_ast) do
    devices_ast
    |> Enum.reduce_while({:ok, []}, fn device_ast, {:ok, acc} ->
      case parse_device_ast(device_ast) do
        {:ok, device} -> {:cont, {:ok, [device | acc]}}
        _ -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, devices} -> {:ok, Enum.reverse(devices)}
      _ -> :unsupported
    end
  end

  defp parse_devices_ast(_other), do: :unsupported

  defp parse_device_ast(
         {{:., _, [{:__aliases__, _, [:EtherCAT, :Simulator, :Slave]}, :from_driver]}, _,
          [
            driver_ast,
            opts_ast
          ]}
       ) do
    with {:ok, driver} <- literal_from_ast(driver_ast),
         true <- is_atom(driver),
         {:ok, opts} <- literal_from_ast(opts_ast),
         name when is_atom(name) <- Keyword.get(opts, :name) do
      {:ok, %{name: name, driver: driver}}
    else
      _ -> :unsupported
    end
  end

  defp parse_device_ast(_other), do: :unsupported

  defp backend_valid?({:udp, %{host: host, port: port}})
       when is_tuple(host) and tuple_size(host) == 4 and is_integer(port) and port >= 0,
       do: true

  defp backend_valid?({:raw, %{interface: interface}})
       when is_binary(interface),
       do: true

  defp backend_valid?(
         {:redundant,
          %{
            primary: {:raw, %{interface: primary}},
            secondary: {:raw, %{interface: secondary}}
          }}
       )
       when is_binary(primary) and is_binary(secondary),
       do: true

  defp backend_valid?(_backend), do: false

  defp extract_module({:defmodule, _, [module_ast, [do: _body]]}), do: module_from_ast(module_ast)

  defp extract_module({:__block__, _, forms}) do
    forms
    |> Enum.filter(&match?({:defmodule, _, _}, &1))
    |> case do
      [form] -> extract_module(form)
      _ -> {:error, :unsupported}
    end
  end

  defp extract_module(_other), do: {:error, :unsupported}

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp module_from_ast({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}
  defp module_from_ast(atom) when is_atom(atom), do: {:ok, atom}
  defp module_from_ast(_other), do: {:error, :unsupported}

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

  defp literal_from_ast(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case literal_from_ast(item) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        _ -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      _ -> :unsupported
    end
  end

  defp literal_from_ast(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_atom(value) or is_nil(value),
       do: {:ok, value}

  defp literal_from_ast(_other), do: :unsupported
end
