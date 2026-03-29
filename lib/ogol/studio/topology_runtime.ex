defmodule Ogol.Studio.TopologyRuntime do
  @moduledoc false

  alias Ogol.Machine.Info
  alias Ogol.Studio.Build
  alias Ogol.Studio.MachineDefinition
  alias Ogol.Studio.MachineDraftStore
  alias Ogol.Studio.Modules
  alias Ogol.Studio.TopologyDefinition
  alias Ogol.Topology.Registry

  @type active_t :: %{
          module: module(),
          root: atom(),
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

  @spec start(String.t(), String.t(), map() | nil) ::
          {:ok, %{module: module(), pid: pid()}}
          | {:blocked, %{reason: :old_code_in_use, module: module(), pids: [pid()]}}
          | {:error, term()}
  def start(id, source, model \\ nil) when is_binary(source) do
    with {:ok, module} <- fetch_module(source, model),
         :ok <- ensure_no_conflicting_topology(module),
         :ok <- ensure_machine_modules(model),
         :ok <- validate_runtime_model(model),
         {:ok, artifact} <- Build.build(id, module, source),
         {:ok, _result} <- Modules.apply(id, artifact),
         {:ok, pid} <- start_module(module) do
      {:ok, %{module: module, pid: pid}}
    end
  end

  @spec stop(String.t(), map() | nil) :: :ok | {:error, term()}
  def stop(source, model \\ nil) when is_binary(source) do
    selected_module = selected_module(source, model)

    case active_topology() do
      nil ->
        {:error, :not_running}

      %{module: ^selected_module, pid: pid} ->
        stop_runtime(pid)

      active ->
        {:error, {:different_topology_running, active}}
    end
  end

  defp selected_module(source, model) do
    case fetch_module(source, model) do
      {:ok, module} -> module
      {:error, _reason} -> nil
    end
  end

  defp fetch_module(_source, %{module_name: module_name}) when is_binary(module_name) do
    {:ok, TopologyDefinition.module_from_name!(module_name)}
  end

  defp fetch_module(source, _model) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, module_ast} <- extract_module_ast(ast) do
      {:ok, module_from_ast!(module_ast)}
    else
      {:error, _reason} -> {:error, :module_not_found}
    end
  end

  defp ensure_no_conflicting_topology(module) do
    case active_topology() do
      nil -> :ok
      %{module: ^module} -> {:error, :already_running}
      active -> {:error, {:topology_already_running, active}}
    end
  end

  defp ensure_machine_modules(nil), do: :ok

  defp ensure_machine_modules(%{machines: machines}) when is_list(machines) do
    machines
    |> Enum.map(& &1.module_name)
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn module_name, :ok ->
      case ensure_machine_module(module_name) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        {:blocked, details} -> {:halt, {:blocked, details}}
      end
    end)
  end

  defp ensure_machine_modules(_model), do: :ok

  defp validate_runtime_model(nil), do: :ok

  defp validate_runtime_model(%{machines: machines} = model) when is_list(machines) do
    root_machine = root_machine(model)

    with {:ok, machine_modules} <- machine_modules_by_name(machines),
         {:ok, root_module} <- root_machine_module(machine_modules, root_machine),
         :ok <- validate_dependency_targets(machine_modules),
         :ok <- validate_observations(model, root_machine, root_module) do
      :ok
    end
  end

  defp validate_runtime_model(_model), do: :ok

  defp ensure_machine_module(module_name) when is_binary(module_name) do
    module = MachineDefinition.module_from_name!(module_name)

    case machine_draft_for_module(module_name) do
      nil ->
        if Code.ensure_loaded?(module) do
          :ok
        else
          {:error, {:machine_module_not_available, module_name}}
        end

      draft ->
        with {:ok, artifact} <- Build.build(module_name, module, draft.source),
             {:ok, _result} <- Modules.apply(module_name, artifact) do
          :ok
        else
          {:blocked, %{module: blocked_module, pids: pids}} ->
            {:blocked, %{reason: :old_code_in_use, module: blocked_module, pids: pids}}

          {:error, %{diagnostics: diagnostics}} ->
            {:error, {:machine_build_failed, draft.id, diagnostics}}

          {:error, reason} ->
            {:error, {:machine_apply_failed, draft.id, reason}}
        end
    end
  end

  defp machine_draft_for_module(module_name) do
    MachineDraftStore.list_drafts()
    |> Enum.find(fn draft ->
      case draft.model do
        %{module_name: ^module_name} -> true
        _ -> false
      end
    end)
  end

  defp start_module(module) do
    try do
      case apply(module, :start, []) do
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
      %{module: module, root: root, pid: pid} = active when is_atom(module) and is_atom(root) and is_pid(pid) ->
        if Process.alive?(pid) do
          active
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_module_ast({:__block__, _, [single]}), do: extract_module_ast(single)
  defp extract_module_ast({:defmodule, _, [module_ast, _body]}), do: {:ok, module_ast}
  defp extract_module_ast(_other), do: {:error, :module_not_found}

  defp module_from_ast!({:__aliases__, _, parts}), do: Module.concat(parts)
  defp module_from_ast!(atom) when is_atom(atom), do: atom

  defp machine_modules_by_name(machines) do
    Enum.reduce_while(machines, {:ok, %{}}, fn
      %{name: name, module_name: module_name}, {:ok, acc}
      when is_binary(name) and is_binary(module_name) ->
        module = MachineDefinition.module_from_name!(module_name)

        case Code.ensure_loaded(module) do
          {:module, ^module} ->
            {:cont, {:ok, Map.put(acc, name, module)}}

          {:error, reason} ->
            {:halt,
             {:error,
              {:invalid_topology,
               "Machine module #{module_name} is not available for topology validation: #{inspect(reason)}"}}}
        end

      _machine, {:ok, _acc} ->
        {:halt, {:error, {:invalid_topology, "Every topology machine must define a name and module name."}}}
    end)
  end

  defp root_machine_module(machine_modules, root_machine) do
    case Map.fetch(machine_modules, root_machine) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, {:invalid_topology, "Root machine #{root_machine} is not declared in this topology."}}
    end
  end

  defp validate_dependency_targets(machine_modules) do
    declared_machine_names = Map.keys(machine_modules) |> MapSet.new()

    Enum.reduce_while(machine_modules, :ok, fn {machine_name, module}, :ok ->
      module
      |> Info.dependencies()
      |> Enum.reduce_while(:ok, fn dependency, :ok ->
        dependency_name = name_to_string(dependency.name)

        if MapSet.member?(declared_machine_names, dependency_name) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            {:invalid_topology,
             "Machine #{machine_name} declares dependency #{dependency_name} but the topology does not declare that machine."}}}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_observation_sources(observations, root_machine, root_module) do
    dependency_names =
      root_module
      |> Info.dependencies()
      |> Enum.map(&name_to_string(&1.name))
      |> MapSet.new()

    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      source = name_to_string(observation.source)

      if MapSet.member?(dependency_names, source) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          {:invalid_topology,
           "Observation source #{source} is not a declared dependency of root #{root_machine}."}}}
      end
    end)
  end

  defp validate_observation_bindings(observations, root_machine, root_module) do
    event_names =
      root_module
      |> Info.events()
      |> Enum.map(&name_to_string(&1.name))
      |> MapSet.new()

    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      as_name = name_to_string(observation.as)

      if MapSet.member?(event_names, as_name) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          {:invalid_topology,
           "Observation binding #{as_name} must be declared as an event on root #{root_machine}."}}}
      end
    end)
  end

  defp name_to_string(name) when is_atom(name), do: Atom.to_string(name)
  defp name_to_string(name) when is_binary(name), do: name
  defp name_to_string(name), do: to_string(name)

  defp root_machine(%{root_machine: root_machine}) when is_binary(root_machine), do: root_machine
  defp root_machine(_model), do: nil

  defp validate_observations(%{observations: observations}, _root_machine, _root_module)
       when observations in [nil, []] do
    :ok
  end

  defp validate_observations(%{observations: observations}, root_machine, root_module)
       when is_binary(root_machine) and is_list(observations) do
    with :ok <- validate_observation_sources(observations, root_machine, root_module),
         :ok <- validate_observation_bindings(observations, root_machine, root_module) do
      :ok
    end
  end

  defp validate_observations(_model, _root_machine, _root_module), do: :ok
end
