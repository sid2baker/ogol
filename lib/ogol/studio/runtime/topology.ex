defmodule Ogol.Studio.TopologyRuntime do
  @moduledoc false

  alias Ogol.Runtime.Hardware.Gateway, as: HardwareGateway
  alias Ogol.Topology.Registry

  @type active_t :: %{
          module: module(),
          topology_id: atom(),
          pid: pid()
        }

  @type status_t :: %{
          selected_module: module() | nil,
          active: active_t() | nil,
          selected_running?: boolean(),
          other_running?: boolean()
        }

  @spec status(String.t(), map() | nil) :: status_t()
  def status(source, model \\ nil) when is_binary(source) do
    selected_module = selected_module(source, model)
    active = active_topology()

    %{
      selected_module: selected_module,
      active: active,
      selected_running?: not is_nil(active) and active.module == selected_module,
      other_running?: not is_nil(active) and active.module != selected_module
    }
  end

  @spec start_loaded(module(), map() | nil) ::
          {:ok, %{module: module(), pid: pid()}}
          | {:error, term()}
  def start_loaded(module, _model \\ nil, opts \\ []) when is_atom(module) do
    with :ok <- preflight_start_loaded(module),
         :ok <- ensure_hardware_runtime_ready(Keyword.get(opts, :hardware_configs, %{})),
         {:ok, pid} <- start_module(module, opts) do
      {:ok, %{module: module, pid: pid}}
    end
  end

  @spec preflight_start_loaded(module()) :: :ok | {:error, term()}
  def preflight_start_loaded(module) when is_atom(module) do
    ensure_no_conflicting_topology(module)
  end

  @spec stop_loaded(module()) :: :ok | {:error, term()}
  def stop_loaded(selected_module) when is_atom(selected_module) do
    case active_topology() do
      nil ->
        {:error, :not_running}

      %{module: ^selected_module, pid: pid} ->
        stop_runtime(pid)

      active ->
        {:error, {:different_topology_running, active}}
    end
  end

  defp selected_module(_source, %{module_name: module_name}) when is_binary(module_name) do
    module_from_name!(module_name)
  end

  defp selected_module(source, _model) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, module_ast} <- extract_module_ast(ast) do
      {:ok, module_from_ast!(module_ast)}
    else
      {:error, _reason} -> {:error, :module_not_found}
    end
    |> case do
      {:ok, module} -> module
      {:error, _reason} -> nil
    end
  end

  defp module_from_name!(module_name) when is_binary(module_name) do
    module_name
    |> String.trim()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
    |> Module.concat()
  end

  defp ensure_no_conflicting_topology(module) do
    case active_topology() do
      nil -> :ok
      %{module: ^module} -> {:error, :already_running}
      active -> {:error, {:topology_already_running, active}}
    end
  end

  defp ensure_hardware_runtime_ready(hardware_configs) when hardware_configs == %{}, do: :ok

  defp ensure_hardware_runtime_ready(%{"ethercat" => _config}) do
    if HardwareGateway.ethercat_master_running?() do
      :ok
    else
      {:error, :ethercat_master_not_running}
    end
  end

  defp ensure_hardware_runtime_ready(_hardware_configs), do: :ok

  defp start_module(module, opts) do
    try do
      case apply(module, :start, [opts]) do
        {:ok, pid} when is_pid(pid) -> {:ok, pid}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_start_result, other}}
      end
    rescue
      error -> {:error, {:start_failed, error}}
    end
  end

  defp stop_runtime(pid) when is_pid(pid) do
    try do
      GenServer.stop(pid, :shutdown)
      :ok
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp active_topology do
    case Registry.active_topology() do
      %{module: module, topology_id: topology_id, pid: pid} = active
      when is_atom(module) and is_atom(topology_id) and is_pid(pid) ->
        if Process.alive?(pid), do: active, else: nil

      _ ->
        nil
    end
  end

  defp extract_module_ast({:__block__, _, [single]}), do: extract_module_ast(single)
  defp extract_module_ast({:defmodule, _, [module_ast, _body]}), do: {:ok, module_ast}
  defp extract_module_ast(_other), do: {:error, :module_not_found}

  defp module_from_ast!({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_from_ast!(atom) when is_atom(atom), do: atom
end
