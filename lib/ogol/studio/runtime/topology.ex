defmodule Ogol.Studio.TopologyRuntime do
  @moduledoc false

  alias Ogol.Session
  alias Ogol.Session.{RuntimeState, State}
  alias Ogol.Topology
  alias Ogol.Topology.Registry

  @type active_t :: %{
          module: module(),
          topology_scope: atom(),
          pid: pid() | nil
        }

  @type status_t :: %{
          selected_module: module() | nil,
          active: active_t() | nil,
          selected_running?: boolean(),
          other_running?: boolean(),
          desired: RuntimeState.realization(),
          observed: RuntimeState.realization(),
          runtime_status: RuntimeState.status(),
          realized?: boolean(),
          dirty?: boolean()
        }

  @spec status(String.t(), map() | nil) :: status_t()
  def status(source, model \\ nil) when is_binary(source) do
    selected_module = selected_module(source, model)
    session_state = Session.get_state()
    runtime = State.runtime(session_state)
    active = active_runtime(session_state)

    %{
      selected_module: selected_module,
      active: active,
      selected_running?: not is_nil(active) and active.module == selected_module,
      other_running?: not is_nil(active) and active.module != selected_module,
      desired: runtime.desired,
      observed: runtime.observed,
      runtime_status: runtime.status,
      realized?: State.runtime_realized?(session_state),
      dirty?: State.runtime_dirty?(session_state)
    }
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

  defp active_topology do
    case Registry.active_topology() do
      %{module: module, topology_scope: topology_scope, pid: pid} = active
      when is_atom(module) and is_atom(topology_scope) and is_pid(pid) ->
        if Process.alive?(pid), do: active, else: nil

      _ ->
        nil
    end
  end

  defp active_runtime(%State{} = session_state) do
    case State.runtime(session_state) do
      %{observed: {:running, _mode}, active_topology_module: module} when is_atom(module) ->
        %{
          module: module,
          topology_scope: Topology.scope(module),
          pid: active_runtime_pid(module)
        }

      _other ->
        nil
    end
  end

  defp active_runtime_pid(module) when is_atom(module) do
    case active_topology() do
      %{module: ^module, pid: pid} when is_pid(pid) -> pid
      _other -> nil
    end
  end

  defp extract_module_ast({:__block__, _, [single]}), do: extract_module_ast(single)
  defp extract_module_ast({:defmodule, _, [module_ast, _body]}), do: {:ok, module_ast}
  defp extract_module_ast(_other), do: {:error, :module_not_found}

  defp module_from_ast!({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_from_ast!(atom) when is_atom(atom), do: atom
end
