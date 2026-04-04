defmodule Ogol.Hardware.EtherCAT.DriverLibrary do
  @moduledoc false

  alias Ogol.Studio.Build

  @driver_specs [
    %{
      id: "ek1100",
      label: "EK1100",
      name: :coupler,
      module: Ogol.Hardware.EtherCAT.Driver.EK1100,
      basename: "ek1100.ex"
    },
    %{
      id: "el1809",
      label: "EL1809",
      name: :inputs,
      module: Ogol.Hardware.EtherCAT.Driver.EL1809,
      basename: "el1809.ex"
    },
    %{
      id: "el2809",
      label: "EL2809",
      name: :outputs,
      module: Ogol.Hardware.EtherCAT.Driver.EL2809,
      basename: "el2809.ex"
    }
  ]

  @spec directory() :: String.t()
  def directory, do: Application.app_dir(:ogol, "priv/examples/ethercat_drivers")

  @spec entries() :: [map()]
  def entries do
    ensure_loaded()
    Enum.map(@driver_specs, &entry_from_spec/1)
  end

  @spec entry(binary() | module()) :: map() | nil
  def entry(id) when is_binary(id) do
    id = id |> String.trim() |> String.downcase()

    @driver_specs
    |> Enum.find(fn spec -> spec.id == id end)
    |> entry_from_spec()
  end

  def entry(module) when is_atom(module) do
    @driver_specs
    |> Enum.find(fn spec -> spec.module == module end)
    |> entry_from_spec()
  end

  def entry(_value), do: nil

  @spec modules() :: [module()]
  def modules do
    ensure_loaded()

    @driver_specs
    |> Enum.map(& &1.module)
    |> Enum.filter(&Code.ensure_loaded?/1)
  end

  @spec module_names() :: [String.t()]
  def module_names do
    Enum.map(@driver_specs, fn spec -> module_name(spec.module) end)
  end

  @spec default_devices() :: [%{name: atom(), driver: module()}]
  def default_devices do
    ensure_loaded()

    Enum.map(@driver_specs, fn spec ->
      %{name: spec.name, driver: spec.module}
    end)
  end

  @spec default_driver(atom()) :: module() | nil
  def default_driver(name) when is_atom(name) do
    ensure_loaded()

    @driver_specs
    |> Enum.find_value(fn
      %{name: ^name, module: module} -> module
      _other -> nil
    end)
  end

  @spec default_device_name(module()) :: atom() | nil
  def default_device_name(module) when is_atom(module) do
    Enum.find_value(@driver_specs, fn
      %{name: name, module: ^module} -> name
      _other -> nil
    end)
  end

  @spec source_path(module()) :: String.t() | nil
  def source_path(module) when is_atom(module) do
    Enum.find_value(@driver_specs, fn
      %{module: ^module, basename: basename} -> Path.join(directory(), basename)
      _other -> nil
    end)
  end

  def source_path(_module), do: nil

  @spec source(module()) :: {:ok, String.t()} | {:error, term()}
  def source(module) when is_atom(module) do
    case source_path(module) do
      nil -> {:error, :unknown_driver}
      path -> File.read(path)
    end
  end

  def source(_module), do: {:error, :unknown_driver}

  @spec ensure_loaded() :: :ok
  def ensure_loaded do
    Enum.each(@driver_specs, &ensure_spec_loaded/1)
    :ok
  end

  @spec recompile(module()) :: :ok | {:error, term()}
  def recompile(module) when is_atom(module) do
    case source_path(module) do
      nil ->
        {:error, :unknown_driver}

      path ->
        purge_compiled(module)

        previous = Code.get_compiler_option(:ignore_module_conflict)
        Code.put_compiler_option(:ignore_module_conflict, true)

        try do
          _ = Code.compile_file(path)
          :ok
        rescue
          error -> {:error, Exception.message(error)}
        catch
          kind, reason -> {:error, Exception.format(kind, reason, __STACKTRACE__)}
        after
          Code.put_compiler_option(:ignore_module_conflict, previous)
        end
    end
  end

  def recompile(_module), do: {:error, :unknown_driver}

  @spec recompile_used_by(Ogol.Hardware.EtherCAT.t()) :: :ok | {:error, [String.t()]}
  def recompile_used_by(%Ogol.Hardware.EtherCAT{slaves: slaves}) when is_list(slaves) do
    slaves
    |> Enum.map(&Map.get(&1, :driver))
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn
      module, :ok when is_atom(module) ->
        case source_path(module) do
          nil ->
            if Code.ensure_loaded?(module) do
              {:cont, :ok}
            else
              {:halt,
               {:error,
                ["EtherCAT driver #{module_name(module)} is not available in the runtime."]}}
            end

          _path ->
            case recompile(module) do
              :ok ->
                {:cont, :ok}

              {:error, reason} ->
                {:halt,
                 {:error,
                  [
                    "EtherCAT driver #{module_name(module)} failed to compile: #{format_error(reason)}"
                  ]}}
            end
        end

      driver, :ok ->
        {:halt, {:error, ["Invalid EtherCAT driver reference: #{inspect(driver)}"]}}
    end)
  end

  @spec runtime_status(module()) :: map()
  def runtime_status(module) when is_atom(module) do
    maybe_ensure_loaded(module)

    case source(module) do
      {:ok, source} ->
        if loaded?(module) do
          %{
            source_digest: Build.digest(source),
            diagnostics: []
          }
        else
          %{
            source_digest: nil,
            diagnostics: []
          }
        end

      _other ->
        %{
          source_digest: nil,
          diagnostics: []
        }
    end
  end

  def runtime_status(_module) do
    %{
      source_digest: nil,
      diagnostics: []
    }
  end

  @spec module_name(module()) :: String.t()
  def module_name(module) when is_atom(module) do
    module
    |> inspect()
    |> String.trim_leading("Elixir.")
  end

  defp ensure_spec_loaded(%{module: module} = spec) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      _ = recompile(module_from_spec(spec))
      :ok
    end
  end

  defp module_from_spec(%{module: module}), do: module

  defp entry_from_spec(nil), do: nil

  defp entry_from_spec(spec) do
    %{
      id: spec.id,
      label: spec.label,
      name: spec.name,
      module: spec.module,
      module_name: module_name(spec.module),
      basename: spec.basename,
      source_path: Path.join(directory(), spec.basename)
    }
  end

  defp purge_compiled(module) do
    Enum.each([module, Module.concat(module, "Simulator")], fn current ->
      if Code.ensure_loaded?(current) do
        :code.purge(current)
        :code.delete(current)
      end
    end)
  end

  defp maybe_ensure_loaded(module) do
    if loaded?(module) do
      :ok
    else
      _ = recompile(module)
      :ok
    end
  end

  defp loaded?(module) when is_atom(module) do
    match?({:file, _path}, :code.is_loaded(module))
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
