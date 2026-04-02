defmodule Ogol.Hardware.Config.Source do
  @moduledoc false

  alias Elixir.EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware.Config
  alias Ogol.Hardware.Config.EtherCAT
  alias Ogol.Hardware.Config.EtherCAT.{Domain, Timing, Transport}

  @definition_attribute :ogol_hardware_definition
  @ethercat_module Ogol.Generated.Hardware.Config.EtherCAT

  @type config_t :: Config.t()

  @spec canonical_module() :: module()
  def canonical_module, do: @ethercat_module

  @spec canonical_module(Config.adapter_t() | config_t()) :: module()
  def canonical_module(:ethercat), do: @ethercat_module
  def canonical_module(%EtherCAT{}), do: @ethercat_module

  @spec default_model(String.t() | atom()) :: config_t() | nil
  def default_model("ethercat"), do: EtherCAT.default()
  def default_model(:ethercat), do: EtherCAT.default()
  def default_model(_other), do: nil

  @spec default_source(String.t() | atom()) :: String.t()
  def default_source(id) do
    case default_model(id) do
      %EtherCAT{} = config -> to_source(config)
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
  def to_source(%EtherCAT{} = config) do
    config
    |> to_quoted(canonical_module(config))
    |> Macro.to_string()
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  @spec from_source(String.t()) :: {:ok, config_t()} | :unsupported
  def from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, definition_term} <- extract_definition_term(ast),
         {:ok, config} <- hardware_config_from_term(definition_term) do
      {:ok, config}
    else
      _ -> :unsupported
    end
  end

  defp to_quoted(%EtherCAT{} = config, module) do
    quote do
      defmodule unquote(alias_ast(module)) do
        @ogol_hardware_definition unquote(Macro.escape(config_literal(config)))

        def definition, do: @ogol_hardware_definition
      end
    end
  end

  defp config_literal(%EtherCAT{} = config) do
    %EtherCAT{
      id: config.id,
      label: config.label,
      inserted_at: config.inserted_at,
      updated_at: config.updated_at,
      transport: config.transport,
      timing: config.timing,
      domains: config.domains,
      slaves: config.slaves,
      meta: %{}
    }
  end

  defp extract_definition_term({:defmodule, _, [_module_ast, [do: body]]}) do
    forms = body_forms(body)
    attr_ast = Enum.find_value(forms, &definition_attribute_ast/1)

    case Enum.find_value(forms, &definition_body_ast/1) do
      nil ->
        :unsupported

      body_ast ->
        body_ast
        |> resolve_config_body(attr_ast)
        |> literal_from_ast()
    end
  end

  defp extract_definition_term({:__block__, _, forms}) do
    forms
    |> Enum.filter(&match?({:defmodule, _, _}, &1))
    |> case do
      [form] -> extract_definition_term(form)
      _ -> :unsupported
    end
  end

  defp extract_definition_term(_other), do: :unsupported

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

  defp definition_attribute_ast({:@, _, [{name, _, [value_ast]}]})
       when name == @definition_attribute,
       do: value_ast

  defp definition_attribute_ast(_other), do: nil

  defp definition_body_ast({:def, _, [{:definition, _, args}, [do: {:__block__, _, [body_ast]}]]})
       when args in [nil, []],
       do: body_ast

  defp definition_body_ast({:def, _, [{:definition, _, args}, [do: body_ast]]})
       when args in [nil, []],
       do: body_ast

  defp definition_body_ast(_other), do: nil

  defp resolve_config_body({:@, _, [{name, _, _}]}, attr_ast)
       when name == @definition_attribute and not is_nil(attr_ast),
       do: attr_ast

  defp resolve_config_body(body_ast, _attr_ast), do: body_ast

  defp module_from_ast({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}
  defp module_from_ast(atom) when is_atom(atom), do: {:ok, atom}
  defp module_from_ast(_other), do: {:error, :unsupported}

  defp hardware_config_from_term(%EtherCAT{} = config) do
    {:ok, normalize_ethercat_defaults(config)}
  end

  defp hardware_config_from_term(map) when is_map(map) do
    with {:ok, transport} <- normalize_transport(map),
         {:ok, timing} <- normalize_timing(map),
         {:ok, domains} <- normalize_domains(Map.get(map, :domains, Map.get(map, "domains", []))),
         {:ok, slaves} <- normalize_slaves(Map.get(map, :slaves, Map.get(map, "slaves", []))) do
      {:ok,
       normalize_ethercat_defaults(%EtherCAT{
         id: fetch_optional(map, :id, EtherCAT.artifact_id()),
         label: fetch_optional(map, :label, EtherCAT.default_label()),
         inserted_at: fetch_optional(map, :inserted_at, nil),
         updated_at: fetch_optional(map, :updated_at, nil),
         transport: transport,
         timing: timing,
         domains: domains,
         slaves: slaves,
         meta: fetch_optional(map, :meta, %{}) || %{}
       })}
    end
  end

  defp hardware_config_from_term(_other), do: :unsupported

  defp normalize_ethercat_defaults(%EtherCAT{} = config) do
    %EtherCAT{
      config
      | id: config.id || EtherCAT.artifact_id(),
        label:
          case config.label do
            label when is_binary(label) and label != "" -> label
            _other -> EtherCAT.default_label()
          end,
        meta: config.meta || %{}
    }
  end

  defp normalize_transport(%Transport{} = transport), do: {:ok, transport}

  defp normalize_transport(map) when is_map(map) do
    transport_value =
      Map.get(
        map,
        :transport,
        Map.get(map, "transport", Map.get(map, :mode, Map.get(map, "mode")))
      )

    with {:ok, mode} <- normalize_transport_mode(transport_value) do
      {:ok,
       %Transport{
         mode: mode,
         bind_ip: Map.get(map, :bind_ip, Map.get(map, "bind_ip")),
         simulator_ip: Map.get(map, :simulator_ip, Map.get(map, "simulator_ip")),
         primary_interface: Map.get(map, :primary_interface, Map.get(map, "primary_interface")),
         secondary_interface:
           Map.get(map, :secondary_interface, Map.get(map, "secondary_interface"))
       }}
    end
  end

  defp normalize_transport(_other), do: :unsupported

  defp normalize_transport_mode(value) when value in [:udp, :raw, :redundant], do: {:ok, value}
  defp normalize_transport_mode(_other), do: :unsupported

  defp normalize_timing(%Timing{} = timing), do: {:ok, timing}

  defp normalize_timing(map) when is_map(map) do
    scan_stable_ms = Map.get(map, :scan_stable_ms, Map.get(map, "scan_stable_ms"))
    scan_poll_ms = Map.get(map, :scan_poll_ms, Map.get(map, "scan_poll_ms"))
    frame_timeout_ms = Map.get(map, :frame_timeout_ms, Map.get(map, "frame_timeout_ms"))

    with {:ok, scan_stable_ms} <- positive_integer(scan_stable_ms),
         {:ok, scan_poll_ms} <- positive_integer(scan_poll_ms),
         {:ok, frame_timeout_ms} <- positive_integer(frame_timeout_ms) do
      {:ok,
       %Timing{
         scan_stable_ms: scan_stable_ms,
         scan_poll_ms: scan_poll_ms,
         frame_timeout_ms: frame_timeout_ms
       }}
    end
  end

  defp normalize_timing(_other), do: :unsupported

  defp normalize_domains(domains) when is_list(domains) do
    domains
    |> Enum.reduce_while({:ok, []}, fn domain, {:ok, acc} ->
      case normalize_domain(domain) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :unsupported -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :unsupported -> :unsupported
    end
  end

  defp normalize_domains(_other), do: :unsupported

  defp normalize_domain(%Domain{} = domain), do: {:ok, domain}

  defp normalize_domain(domain) when is_list(domain) do
    normalize_domain(Enum.into(domain, %{}))
  end

  defp normalize_domain(domain) when is_map(domain) do
    with {:ok, id} <- fetch_atom(domain, :id),
         {:ok, cycle_time_us} <- fetch_positive_integer(domain, :cycle_time_us),
         {:ok, miss_threshold} <- fetch_positive_integer(domain, :miss_threshold),
         {:ok, recovery_threshold} <- fetch_positive_integer(domain, :recovery_threshold) do
      {:ok,
       %Domain{
         id: id,
         cycle_time_us: cycle_time_us,
         miss_threshold: miss_threshold,
         recovery_threshold: recovery_threshold
       }}
    end
  end

  defp normalize_domain(_other), do: :unsupported

  defp normalize_slaves(slaves) when is_list(slaves) do
    if Enum.all?(slaves, &match?(%SlaveConfig{}, &1)) do
      {:ok, slaves}
    else
      :unsupported
    end
  end

  defp normalize_slaves(_other), do: :unsupported

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_other), do: :unsupported

  defp fetch_atom(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_atom(value) -> {:ok, value}
      _ -> :unsupported
    end
  end

  defp fetch_positive_integer(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_integer(value) and value > 0 -> {:ok, value}
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

  defp literal_from_ast({:%, _, [module_ast, attrs_ast]}) do
    with {:ok, module} <- literal_from_ast(module_ast),
         {:ok, module} <- ensure_struct_module(module),
         {:ok, attrs} <- literal_from_ast(attrs_ast) do
      {:ok, struct(module, attrs)}
    else
      _ -> :unsupported
    end
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
    |> case do
      {:ok, %{__struct__: module} = attrs} when is_atom(module) ->
        case ensure_struct_module(module) do
          {:ok, module} -> {:ok, struct(module, Map.delete(attrs, :__struct__))}
          :error -> :unsupported
        end

      result ->
        result
    end
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

  defp ensure_struct_module(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :__struct__, 0), do: {:ok, module}, else: :error

      _ ->
        :error
    end
  end
end
