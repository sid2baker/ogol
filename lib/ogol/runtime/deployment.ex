defmodule Ogol.Runtime.Deployment do
  @moduledoc false

  use GenServer

  alias Ogol.Hardware.Source, as: HardwareSource
  alias Ogol.Machine.Contract, as: MachineContract
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Build.Artifact
  alias Ogol.Session.Workspace
  alias Ogol.Session.Workspace.SourceDraft
  alias Ogol.Topology.Source, as: TopologySource

  @dispatch_timeout 15_000
  @source_backed_kinds [:hardware, :machine, :topology, :sequence]

  defmodule LoadedArtifact do
    @moduledoc false

    @type t :: %__MODULE__{
            id: {atom(), String.t()},
            kind: atom(),
            artifact_id: String.t(),
            module: module() | nil,
            source_digest: String.t() | nil,
            diagnostics: [String.t()],
            blocked_reason: term() | nil,
            lingering_pids: [pid()]
          }

    defstruct [
      :id,
      :kind,
      :artifact_id,
      :module,
      :source_digest,
      diagnostics: [],
      blocked_reason: nil,
      lingering_pids: []
    ]
  end

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            loaded_artifacts: %{optional({atom(), String.t()}) => LoadedArtifact.t()}
          }

    defstruct loaded_artifacts: %{}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def artifact_id(kind, id) when is_atom(kind), do: {kind, to_string(id)}

  def compile_machine(%Workspace{} = workspace, id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_artifact, workspace, :machine, id}, @dispatch_timeout)
  end

  def compile_topology(%Workspace{} = workspace, id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_artifact, workspace, :topology, id}, @dispatch_timeout)
  end

  def compile_sequence(%Workspace{} = workspace, id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_artifact, workspace, :sequence, id}, @dispatch_timeout)
  end

  def compile_hardware(%Workspace{} = workspace, id) when is_binary(id) do
    GenServer.call(
      __MODULE__,
      {:compile_artifact, workspace, :hardware, id},
      @dispatch_timeout
    )
  end

  def machine_contract(%Workspace{} = workspace, module_name) when is_binary(module_name) do
    GenServer.call(__MODULE__, {:machine_contract, workspace, module_name}, @dispatch_timeout)
  end

  def prepare_topology_runtime(%Workspace{} = workspace, id) when is_binary(id) do
    GenServer.call(__MODULE__, {:prepare_topology_runtime, workspace, id}, @dispatch_timeout)
  end

  def delete_artifact(kind, id) when kind in @source_backed_kinds and is_binary(id) do
    GenServer.call(__MODULE__, {:delete_artifact, kind, id}, @dispatch_timeout)
  end

  def reset do
    GenServer.call(__MODULE__, :reset, @dispatch_timeout)
  end

  def current(kind, id) when is_atom(kind) and is_binary(id), do: current(artifact_id(kind, id))

  def current(id) do
    GenServer.call(__MODULE__, {:current, id})
  end

  def status(kind, id) when is_atom(kind) and is_binary(id), do: status(artifact_id(kind, id))

  def status(id) do
    GenServer.call(__MODULE__, {:status, id})
  end

  def artifact_statuses do
    GenServer.call(__MODULE__, :artifact_statuses)
  end

  def apply_artifact(id, %Artifact{} = artifact) do
    GenServer.call(__MODULE__, {:apply_artifact, id, artifact}, @dispatch_timeout)
  end

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call(
        {:compile_artifact, %Workspace{} = workspace, kind, id},
        _from,
        %State{} = state
      )
      when kind in @source_backed_kinds do
    {reply, next_state} = execute_compile_artifact(state, workspace, kind, id)
    {:reply, reply, next_state}
  end

  def handle_call(
        {:prepare_topology_runtime, %Workspace{} = workspace, id},
        _from,
        %State{} = state
      ) do
    {reply, next_state} = execute_prepare_topology_runtime(state, workspace, id)
    {:reply, reply, next_state}
  end

  def handle_call({:delete_artifact, kind, id}, _from, %State{} = state)
      when kind in @source_backed_kinds do
    {reply, next_state} = execute_delete_artifact(state, kind, id)
    {:reply, reply, next_state}
  end

  def handle_call(:reset, _from, %State{} = state) do
    {reply, next_state} = reset_internal(state)
    {:reply, reply, next_state}
  end

  def handle_call({:current, id}, _from, %State{} = state) do
    reply =
      case fetch_loaded_artifact(state, id) do
        %LoadedArtifact{module: module} when is_atom(module) -> {:ok, module}
        _ -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:status, id}, _from, %State{} = state) do
    reply =
      case fetch_loaded_artifact(state, id) do
        %LoadedArtifact{} = entry -> {:ok, artifact_status(entry)}
        nil -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:artifact_statuses, _from, %State{} = state) do
    reply =
      state.loaded_artifacts
      |> Map.values()
      |> Enum.map(&artifact_status/1)
      |> Enum.sort_by(fn status -> {status.kind, status.artifact_id} end)

    {:reply, reply, state}
  end

  def handle_call({:apply_artifact, id, %Artifact{} = artifact}, _from, %State{} = state) do
    {reply, next_state} = apply_artifact_internal(state, id, artifact)
    {:reply, reply, next_state}
  end

  def handle_call(
        {:machine_contract, %Workspace{} = workspace, module_name},
        _from,
        %State{} = state
      )
      when is_binary(module_name) do
    {reply, next_state} = execute_machine_contract(state, workspace, module_name)
    {:reply, reply, next_state}
  end

  defp execute_compile_artifact(%State{} = state, %Workspace{} = workspace, :sequence, id) do
    case Workspace.fetch(workspace, :sequence, id) do
      nil ->
        {{:error, :not_found}, state}

      draft ->
        execute_sequence_load(state, workspace, id, draft.source)
    end
  end

  defp execute_compile_artifact(%State{} = state, %Workspace{} = workspace, :topology, id) do
    case Workspace.fetch(workspace, :topology, id) do
      nil ->
        {{:error, :not_found}, state}

      draft ->
        execute_topology_load(state, workspace, id, draft.source, Map.get(draft, :model))
    end
  end

  defp execute_compile_artifact(%State{} = state, %Workspace{} = workspace, kind, id) do
    case workspace_fetch(workspace, kind, id) do
      nil ->
        {{:error, :not_found}, state}

      %{source: source} = draft ->
        execute_compile_and_load(state, kind, id, source, Map.get(draft, :model))
    end
  end

  defp execute_prepare_topology_runtime(%State{} = state, %Workspace{} = workspace, id) do
    with {:ok, loaded_state} <- compile_workspace_artifacts(state, workspace),
         %{source: source} = draft <- Workspace.fetch(workspace, :topology, id),
         {:ok, module} <- topology_runtime_module(source, Map.get(draft, :model)),
         {:ok, topology_model} <- runtime_topology_model(module),
         {:ok, prepared_state, hardware} <-
           maybe_load_hardware_modules(loaded_state, workspace, topology_model),
         {:ok, machine_state} <-
           ensure_machine_runtime_contexts(prepared_state, workspace, topology_model) do
      {{:ok,
        %{
          topology_id: id,
          module: module,
          topology_model: topology_model,
          hardware: hardware
        }}, machine_state}
    else
      nil ->
        {{:error, :not_found}, state}

      {:blocked, details, next_state} ->
        {{:blocked, details}, next_state}

      {:error, reason, next_state} ->
        {{:error, reason}, next_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp reset_internal(%State{} = state) do
    blocked =
      Enum.flat_map(Map.values(state.loaded_artifacts), fn
        %LoadedArtifact{module: module, id: id} when is_atom(module) ->
          unload_block_reason(id, module)

        _entry ->
          []
      end)

    case blocked do
      [] ->
        Enum.each(Map.values(state.loaded_artifacts), fn
          %LoadedArtifact{module: module} when is_atom(module) -> unload_module(module)
          _entry -> :ok
        end)

        {:ok, %State{state | loaded_artifacts: %{}}}

      blocked_modules ->
        {{:blocked, %{reason: :old_code_in_use, modules: blocked_modules}}, state}
    end
  end

  defp execute_delete_artifact(%State{} = state, kind, id) when kind in @source_backed_kinds do
    artifact_key = artifact_id(kind, id)

    case fetch_loaded_artifact(state, artifact_key) do
      nil ->
        {:ok, state}

      %LoadedArtifact{module: module} = entry when is_atom(module) ->
        case lingering_pids(module) do
          [] ->
            unload_module(module)
            {{:ok, :deleted}, remove_loaded_artifact(state, artifact_key)}

          pids ->
            next_state =
              state
              |> put_loaded_artifact(%{
                entry
                | blocked_reason: :old_code_in_use,
                  diagnostics: [],
                  lingering_pids: pids
              })

            {{:blocked, artifact_status(fetch_loaded_artifact(next_state, artifact_key))},
             next_state}
        end

      %LoadedArtifact{} ->
        {{:ok, :deleted}, remove_loaded_artifact(state, artifact_key)}
    end
  end

  defp compile_workspace_artifacts(%State{} = state, %Workspace{} = workspace) do
    Enum.reduce_while(@source_backed_kinds, {:ok, state}, fn kind, {:ok, current_state} ->
      workspace_entries_for_kind(workspace, kind)
      |> Enum.reduce_while({:ok, current_state}, fn draft, {:ok, runtime_state} ->
        artifact_id = artifact_id(kind, draft.id)

        case execute_compile_artifact(runtime_state, workspace, kind, draft.id) do
          {{:ok, _status}, next_state} ->
            {:cont, {:ok, next_state}}

          {{:error, :not_found}, next_state} ->
            {:halt, {:error, {:artifact_not_found, artifact_id}, next_state}}

          {{:error, _status}, next_state} ->
            {:halt, {:error, {:artifact_load_failed, artifact_id}, next_state}}
        end
      end)
      |> case do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, _reason, _next_state} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, next_state} -> {:ok, next_state}
      {:error, reason, next_state} -> {:error, reason, next_state}
    end
  end

  defp workspace_entries_for_kind(%Workspace{} = workspace, kind)
       when kind in @source_backed_kinds do
    Workspace.list_entries(workspace, kind)
  end

  defp execute_sequence_load(%State{} = state, %Workspace{} = workspace, id, source) do
    case build_sequence_artifact(state, workspace, id, source) do
      {:ok, artifact, prepared_state} ->
        case apply_artifact_internal(prepared_state, artifact_id(:sequence, id), artifact) do
          {{:ok, status}, next_state} -> {{:ok, status}, next_state}
          {{:error, reason}, next_state} -> {{:error, reason}, next_state}
        end

      {:error, :module_not_found} ->
        {{:error, :module_not_found}, state}

      {:error, diagnostics} ->
        next_state =
          put_loaded_artifact(
            state,
            load_failure_entry(:sequence, id, nil, diagnostics)
          )

        {{:error, artifact_status(fetch_loaded_artifact(next_state, artifact_id(:sequence, id)))},
         next_state}
    end
  end

  defp execute_topology_load(%State{} = state, %Workspace{} = workspace, id, source, model) do
    case ensure_topology_compile_context(state, workspace, source, model) do
      {:ok, prepared_state} ->
        execute_compile_and_load(prepared_state, :topology, id, source, model)

      {:error, diagnostics, prepared_state} ->
        next_state =
          put_loaded_artifact(
            prepared_state,
            load_failure_entry(:topology, id, nil, diagnostics)
          )

        {{:error, artifact_status(fetch_loaded_artifact(next_state, artifact_id(:topology, id)))},
         next_state}
    end
  end

  defp execute_compile_and_load(%State{} = state, kind, id, source, model) do
    case build_artifact(kind, id, source, model) do
      {:ok, artifact} ->
        case apply_artifact_internal(state, artifact_id(kind, id), artifact) do
          {{:ok, status}, next_state} -> {{:ok, status}, next_state}
          {{:error, reason}, next_state} -> {{:error, reason}, next_state}
        end

      {:error, :module_not_found} ->
        {{:error, :module_not_found}, state}

      {:error, diagnostics} ->
        next_state =
          put_loaded_artifact(
            state,
            load_failure_entry(kind, id, nil, diagnostics)
          )

        {{:error, artifact_status(fetch_loaded_artifact(next_state, artifact_id(kind, id)))},
         next_state}
    end
  end

  defp execute_machine_contract(%State{} = state, %Workspace{} = workspace, module_name) do
    case workspace_entry_by_module(workspace, :machine, module_name) do
      nil ->
        {{:error, :not_found}, state}

      draft ->
        case ensure_workspace_entry_current(state, workspace, :machine, draft) do
          {:ok, next_state, module} ->
            case MachineContract.from_module(module) do
              {:ok, contract} -> {{:ok, contract}, next_state}
              {:error, :missing_contract} -> {{:error, :missing_contract}, next_state}
            end

          {:error, _reason, next_state} ->
            {{:error, :not_found}, next_state}
        end
    end
  end

  defp maybe_load_hardware_modules(%State{} = state, %Workspace{} = workspace, %{
         machines: machines
       })
       when is_list(machines) do
    if topology_requires_hardware?(machines) do
      with {:ok, runtime_state, modules} <-
             ensure_hardware_modules_current(state, workspace),
           {:ok, hardware} <- load_hardware_modules(modules),
           true <- map_size(hardware) > 0 do
        {:ok, runtime_state, hardware}
      else
        {:blocked, _details, _runtime_state} = blocked -> blocked
        {:error, _reason, _runtime_state} = error -> error
        {:error, reason} -> {:error, reason, state}
        false -> {:error, :no_hardware_available, state}
      end
    else
      {:ok, state, %{}}
    end
  end

  defp maybe_load_hardware_modules(
         %State{} = state,
         %Workspace{} = _workspace,
         _topology_model
       ),
       do: {:ok, state, %{}}

  defp ensure_hardware_modules_current(%State{} = state, %Workspace{} = workspace) do
    workspace
    |> Workspace.list_entries(:hardware)
    |> Enum.reduce_while({:ok, state, %{}}, fn draft, {:ok, runtime_state, modules} ->
      artifact_key = artifact_id(:hardware, draft.id)
      draft_source_digest = Build.digest(draft.source)

      result =
        case fetch_loaded_artifact(runtime_state, artifact_key) do
          %LoadedArtifact{
            module: module,
            source_digest: source_digest,
            blocked_reason: nil
          }
          when is_atom(module) ->
            if source_digest == draft_source_digest do
              {:ok, runtime_state, module}
            else
              compile_hardware_module(runtime_state, workspace, draft.id)
            end

          _ ->
            compile_hardware_module(runtime_state, workspace, draft.id)
        end

      case result do
        {:ok, next_state, module} ->
          {:cont, {:ok, next_state, Map.put(modules, draft.id, module)}}

        {:blocked, _details, _next_state} = blocked ->
          {:halt, blocked}

        {:error, _reason, _next_state} = error ->
          {:halt, error}
      end
    end)
  end

  defp compile_hardware_module(%State{} = state, %Workspace{} = workspace, draft_id) do
    case execute_compile_artifact(state, workspace, :hardware, draft_id) do
      {{:ok, %{module: module}}, next_state} -> {:ok, next_state, module}
      {{:error, :module_not_found}, _next_state} -> {:error, :module_not_found, state}
      {{:error, status}, next_state} -> {:blocked, status, next_state}
    end
  end

  defp load_hardware_modules(modules) when is_map(modules) do
    Enum.reduce_while(modules, {:ok, %{}}, fn {draft_id, module}, {:ok, hardware} ->
      case load_hardware_module(module) do
        {:ok, hardware_module} when is_atom(hardware_module) ->
          {:cont, {:ok, Map.put(hardware, draft_id, hardware_module)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp load_hardware_module(module) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:hardware_module_not_loaded, module}}

      not function_exported?(module, :hardware, 0) ->
        {:error, {:hardware_module_missing_definition, module}}

      true ->
        {:ok, module}
    end
  end

  defp ensure_machine_runtime_contexts(%State{} = state, %Workspace{} = workspace, %{
         machines: machines
       })
       when is_list(machines) do
    machines
    |> Enum.map(&machine_module_reference/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, state}, fn module_reference, {:ok, current_state} ->
      case ensure_machine_runtime_current(current_state, workspace, module_reference) do
        {:ok, next_state} ->
          {:cont, {:ok, next_state}}

        {:blocked, details, next_state} ->
          {:halt, {:blocked, details, next_state}}

        {:error, reason, next_state} ->
          {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp ensure_machine_runtime_contexts(%State{} = state, %Workspace{} = _workspace, _model),
    do: {:ok, state}

  defp ensure_machine_runtime_current(
         %State{} = state,
         %Workspace{} = workspace,
         module_reference
       ) do
    {module_name, module} = machine_module_identity(module_reference)

    case machine_draft_for_module(workspace, module_reference) do
      nil ->
        if Code.ensure_loaded?(module) do
          {:ok, state}
        else
          {:error, {:machine_module_not_available, module_name}, state}
        end

      %SourceDraft{} = draft ->
        artifact_key = artifact_id(:machine, draft.id)
        draft_source_digest = Build.digest(draft.source)

        case fetch_loaded_artifact(state, artifact_key) do
          %LoadedArtifact{
            module: ^module,
            source_digest: source_digest,
            blocked_reason: nil
          } ->
            if source_digest == draft_source_digest do
              {:ok, state}
            else
              compile_machine_runtime_module(state, workspace, module_name, draft.id)
            end

          _ ->
            compile_machine_runtime_module(state, workspace, module_name, draft.id)
        end
    end
  end

  defp compile_machine_runtime_module(
         %State{} = state,
         %Workspace{} = workspace,
         module_name,
         draft_id
       ) do
    case execute_compile_artifact(state, workspace, :machine, draft_id) do
      {{:ok, _status}, next_state} ->
        {:ok, next_state}

      {{:error, %{} = status}, next_state} ->
        {:blocked, status, next_state}

      {{:error, :module_not_found}, next_state} ->
        {:error, {:machine_module_not_available, module_name}, next_state}
    end
  end

  defp build_artifact(:machine, id, source, _model) do
    with {:ok, module} <- MachineSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} ->
        {:error, :module_not_found}

      {:error, %{diagnostics: diagnostics}} ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, reason} ->
        {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:topology, id, source, %{module_name: module_name})
       when is_binary(module_name) do
    with {:ok, artifact} <- Build.build(id, TopologySource.module_from_name!(module_name), source) do
      {:ok, artifact}
    else
      {:error, %{diagnostics: diagnostics}} ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, reason} ->
        {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:topology, id, source, _model) do
    with {:ok, module} <- TopologySource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} ->
        {:error, :module_not_found}

      {:error, %{diagnostics: diagnostics}} ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, reason} ->
        {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:hardware, id, source, _model) do
    with {:ok, module} <- HardwareSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} ->
        {:error, :module_not_found}

      {:error, %{diagnostics: diagnostics}} ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, reason} ->
        {:error, [inspect(reason)]}
    end
  end

  defp ensure_topology_compile_context(%State{} = state, %Workspace{} = workspace, source, model) do
    case topology_compile_projection(source, model) do
      {:ok, topology_model} ->
        case ensure_machine_runtime_contexts(state, workspace, topology_model) do
          {:ok, next_state} ->
            {:ok, next_state}

          {:blocked, details, next_state} ->
            {:error, topology_dependency_diagnostics(details), next_state}

          {:error, reason, next_state} ->
            {:error, topology_dependency_diagnostics(reason), next_state}
        end

      {:error, _diagnostics} ->
        {:ok, state}
    end
  end

  defp build_sequence_artifact(%State{} = state, %Workspace{} = workspace, id, source) do
    with {:ok, parsed} <- SequenceSource.from_source(source),
         {:ok, prepared_state} <-
           ensure_sequence_runtime_context(state, workspace, parsed.topology_module_name),
         {:ok, module} <- SequenceSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact, prepared_state}
    else
      {:error, :module_not_found} ->
        {:error, :module_not_found}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, %{diagnostics: diagnostics}} ->
        {:error, normalize_diagnostics(diagnostics)}

      {:error, reason} ->
        {:error, [inspect(reason)]}
    end
  end

  defp ensure_sequence_runtime_context(
         %State{} = state,
         %Workspace{} = workspace,
         topology_module_name
       )
       when is_binary(topology_module_name) do
    with {:ok, draft} <- fetch_sequence_topology_entry(workspace, topology_module_name),
         {:ok, topology_state} <-
           ensure_sequence_dependency_loaded(state, workspace, :topology, draft),
         {:ok, topology_model} <- topology_model_from_entry(draft, topology_module_name),
         {:ok, machine_state} <-
           ensure_sequence_machine_contexts(topology_state, workspace, topology_model.machines) do
      {:ok, machine_state}
    end
  end

  defp ensure_sequence_machine_contexts(%State{} = state, %Workspace{} = workspace, machines)
       when is_list(machines) do
    Enum.reduce_while(machines, {:ok, state}, fn machine, {:ok, current_state} ->
      case ensure_sequence_machine_context(
             current_state,
             workspace,
             Map.get(machine, :module_name)
           ) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_sequence_machine_contexts(%State{} = state, %Workspace{} = _workspace, _machines),
    do: {:ok, state}

  defp ensure_sequence_machine_context(%State{} = state, %Workspace{} = workspace, module_name)
       when is_binary(module_name) do
    with {:ok, draft} <- fetch_sequence_machine_entry(workspace, module_name),
         {:ok, next_state} <-
           ensure_sequence_dependency_loaded(state, workspace, :machine, draft) do
      {:ok, next_state}
    end
  end

  defp ensure_sequence_machine_context(%State{} = state, %Workspace{} = _workspace, _module_name),
    do: {:ok, state}

  defp ensure_sequence_dependency_loaded(%State{} = state, %Workspace{} = workspace, kind, draft) do
    case ensure_workspace_entry_current(state, workspace, kind, draft) do
      {:ok, next_state, _module} ->
        {:ok, next_state}

      {:error, reason, _next_state} ->
        {:error, dependency_load_diagnostics(kind, draft.id, reason)}
    end
  end

  defp fetch_sequence_topology_entry(%Workspace{} = workspace, module_name) do
    case workspace_entry_by_module(workspace, :topology, module_name) do
      nil ->
        {:error,
         [
           "Sequence compile targets topology #{module_name}, but that topology is not present in the current workspace."
         ]}

      draft ->
        {:ok, draft}
    end
  end

  defp fetch_sequence_machine_entry(%Workspace{} = workspace, module_name) do
    case workspace_entry_by_module(workspace, :machine, module_name) do
      nil ->
        {:error,
         [
           "Sequence compile references machine module #{module_name}, but that machine is not present in the current workspace."
         ]}

      draft ->
        {:ok, draft}
    end
  end

  defp ensure_workspace_entry_current(%State{} = state, %Workspace{} = workspace, kind, %{
         id: id,
         source: source
       })
       when kind in @source_backed_kinds and is_binary(id) and is_binary(source) do
    source_digest = Build.digest(source)

    case fetch_loaded_artifact(state, artifact_id(kind, id)) do
      %LoadedArtifact{module: module, source_digest: ^source_digest, blocked_reason: nil}
      when is_atom(module) ->
        {:ok, state, module}

      _ ->
        compile_workspace_entry(state, workspace, kind, id)
    end
  end

  defp compile_workspace_entry(%State{} = state, %Workspace{} = workspace, kind, id)
       when kind in @source_backed_kinds do
    case execute_compile_artifact(state, workspace, kind, id) do
      {{:ok, %{module: module}}, next_state} when is_atom(module) ->
        {:ok, next_state, module}

      {{:error, reason}, next_state} ->
        {:error, reason, next_state}
    end
  end

  defp dependency_load_diagnostics(kind, id, %{} = status) do
    diagnostics = normalize_diagnostics(Map.get(status, :diagnostics, []))

    cond do
      diagnostics != [] ->
        diagnostics

      blocked_reason = Map.get(status, :blocked_reason) ->
        ["#{humanize_kind(kind)} #{id} is blocked in the runtime: #{inspect(blocked_reason)}"]

      true ->
        ["#{humanize_kind(kind)} #{id} could not be loaded into the runtime."]
    end
  end

  defp dependency_load_diagnostics(kind, id, :module_not_found) do
    ["#{humanize_kind(kind)} #{id} does not define a module."]
  end

  defp dependency_load_diagnostics(kind, id, reason) do
    ["#{humanize_kind(kind)} #{id} could not be loaded into the runtime: #{inspect(reason)}"]
  end

  defp workspace_entry_by_module(%Workspace{} = workspace, :machine, module_name) do
    Enum.find(
      Workspace.list_entries(workspace, :machine),
      &(entry_module_name(:machine, &1) == module_name)
    )
  end

  defp workspace_entry_by_module(%Workspace{} = workspace, :topology, module_name) do
    Enum.find(
      Workspace.list_entries(workspace, :topology),
      &(entry_module_name(:topology, &1) == module_name)
    )
  end

  defp workspace_entry_by_module(%Workspace{} = _workspace, _kind, _module_name), do: nil

  defp topology_runtime_module(_source, %{module_name: module_name})
       when is_binary(module_name) do
    {:ok, TopologySource.module_from_name!(module_name)}
  end

  defp topology_runtime_module(source, _model) when is_binary(source) do
    TopologySource.module_from_source(source)
  end

  defp runtime_topology_model(module) when is_atom(module) do
    if function_exported?(module, :__ogol_topology__, 0) do
      {:ok, apply(module, :__ogol_topology__, [])}
    else
      {:error, :topology_model_not_available}
    end
  end

  defp apply_artifact_internal(%State{} = state, id, %Artifact{} = artifact) do
    entry =
      fetch_loaded_artifact(state, id) ||
        %LoadedArtifact{id: id, kind: elem(id, 0), artifact_id: elem(id, 1)}

    cond do
      not is_nil(entry.module) and entry.module != artifact.module ->
        next_state =
          state
          |> put_loaded_artifact(%{
            entry
            | blocked_reason: {:module_mismatch, entry.module, artifact.module},
              diagnostics: []
          })

        {{:error, artifact_status(fetch_loaded_artifact(next_state, id))}, next_state}

      old_code?(artifact.module) and not :code.soft_purge(artifact.module) ->
        lingering_pids = lingering_pids(artifact.module)

        next_state =
          state
          |> put_loaded_artifact(%{
            entry
            | module: artifact.module,
              source_digest: artifact.source_digest,
              blocked_reason: :old_code_in_use,
              diagnostics: [],
              lingering_pids: lingering_pids
          })

        {{:error, artifact_status(fetch_loaded_artifact(next_state, id))}, next_state}

      true ->
        case :code.load_binary(
               artifact.module,
               String.to_charlist(Atom.to_string(artifact.module)),
               artifact.beam
             ) do
          {:module, module} ->
            next_state =
              state
              |> put_loaded_artifact(%{
                entry
                | module: module,
                  source_digest: artifact.source_digest,
                  blocked_reason: nil,
                  diagnostics: [],
                  lingering_pids: []
              })

            {{:ok, artifact_status(fetch_loaded_artifact(next_state, id))}, next_state}

          {:error, reason} ->
            next_state =
              state
              |> put_loaded_artifact(%{
                entry
                | blocked_reason: reason,
                  diagnostics: [inspect(reason)],
                  lingering_pids: []
              })

            {{:error, artifact_status(fetch_loaded_artifact(next_state, id))}, next_state}
        end
    end
  end

  defp artifact_status(%LoadedArtifact{} = entry) do
    %{
      id: entry.id,
      kind: entry.kind,
      artifact_id: entry.artifact_id,
      module: entry.module,
      source_digest: entry.source_digest,
      blocked_reason: entry.blocked_reason,
      lingering_pids: entry.lingering_pids,
      diagnostics: entry.diagnostics
    }
  end

  defp fetch_loaded_artifact(%State{} = state, id), do: Map.get(state.loaded_artifacts, id)

  defp put_loaded_artifact(%State{} = state, %LoadedArtifact{id: id} = entry) do
    put_in(state.loaded_artifacts[id], entry)
  end

  defp remove_loaded_artifact(%State{} = state, id) do
    %State{state | loaded_artifacts: Map.delete(state.loaded_artifacts, id)}
  end

  defp load_failure_entry(kind, id, module, diagnostics) do
    %LoadedArtifact{
      id: artifact_id(kind, id),
      kind: kind,
      artifact_id: id,
      module: module,
      source_digest: nil,
      diagnostics: normalize_diagnostics(diagnostics),
      blocked_reason: :load_failed,
      lingering_pids: []
    }
  end

  defp workspace_fetch(%Workspace{} = workspace, :machine, id),
    do: Workspace.fetch(workspace, :machine, id)

  defp workspace_fetch(%Workspace{} = workspace, :topology, id),
    do: Workspace.fetch(workspace, :topology, id)

  defp workspace_fetch(%Workspace{} = workspace, :sequence, id),
    do: Workspace.fetch(workspace, :sequence, id)

  defp workspace_fetch(%Workspace{} = workspace, :hardware, id),
    do: Workspace.fetch(workspace, :hardware, id)

  defp machine_draft_for_module(%Workspace{} = workspace, module_name)
       when is_binary(module_name) do
    workspace_entry_by_module(workspace, :machine, module_name)
  end

  defp machine_draft_for_module(%Workspace{} = workspace, module) when is_atom(module) do
    machine_draft_for_module(workspace, Atom.to_string(module) |> String.trim_leading("Elixir."))
  end

  defp topology_model_from_entry(%{model: model}, _topology_module_name) when is_map(model) do
    {:ok, model}
  end

  defp topology_model_from_entry(%{source: source}, topology_module_name)
       when is_binary(source) do
    case TopologySource.contract_projection_from_source(source) do
      {:ok, model} ->
        {:ok, model}

      {:error, diagnostics} ->
        {:error,
         [
           "Topology #{topology_module_name} could not be recovered from workspace source: #{List.first(diagnostics)}"
         ]}
    end
  end

  defp topology_compile_projection(_source, %{machines: _machines} = model) when is_map(model) do
    {:ok, model}
  end

  defp topology_compile_projection(source, _model) when is_binary(source) do
    TopologySource.contract_projection_from_source(source)
  end

  defp topology_compile_projection(_source, _model), do: {:error, :projection_unavailable}

  defp topology_dependency_diagnostics(%{artifact_id: artifact_id} = status)
       when is_binary(artifact_id) do
    dependency_load_diagnostics(:machine, artifact_id, status)
  end

  defp topology_dependency_diagnostics({:machine_module_not_available, module_name})
       when is_binary(module_name) do
    [
      "Topology compile references machine module #{module_name}, but that machine is not available in the current workspace."
    ]
  end

  defp topology_dependency_diagnostics(reason) do
    ["Topology compile could not prepare referenced machines: #{inspect(reason)}"]
  end

  defp entry_module_name(:machine, %{model: %{module_name: module_name}})
       when is_binary(module_name),
       do: module_name

  defp entry_module_name(:machine, %{source: source}) when is_binary(source) do
    case MachineSource.module_from_source(source) do
      {:ok, module} -> Atom.to_string(module) |> String.trim_leading("Elixir.")
      _ -> nil
    end
  end

  defp entry_module_name(:topology, %{model: %{module_name: module_name}})
       when is_binary(module_name),
       do: module_name

  defp entry_module_name(:topology, %{source: source}) when is_binary(source) do
    case TopologySource.module_from_source(source) do
      {:ok, module} -> Atom.to_string(module) |> String.trim_leading("Elixir.")
      _ -> nil
    end
  end

  defp entry_module_name(_kind, _entry), do: nil

  defp topology_requires_hardware?(machines) do
    Enum.any?(machines, fn
      %{wiring: %Ogol.Topology.Wiring{} = wiring} ->
        not Ogol.Topology.Wiring.empty?(wiring)

      _ ->
        false
    end)
  end

  defp machine_module_reference(%{module_name: module_name}) when is_binary(module_name),
    do: module_name

  defp machine_module_reference(%{module: module}) when is_atom(module), do: module
  defp machine_module_reference(_machine), do: nil

  defp machine_module_identity(module_name) when is_binary(module_name) do
    {module_name, MachineSource.module_from_name!(module_name)}
  end

  defp machine_module_identity(module) when is_atom(module) do
    {Atom.to_string(module) |> String.trim_leading("Elixir."), module}
  end

  defp humanize_kind(:machine), do: "machine"
  defp humanize_kind(:topology), do: "topology"
  defp humanize_kind(:sequence), do: "sequence"
  defp humanize_kind(:hardware), do: "hardware"
  defp humanize_kind(kind), do: to_string(kind)

  defp old_code?(module) when is_atom(module), do: :erlang.check_old_code(module)
  defp old_code?(_module), do: false

  defp lingering_pids(module) do
    Process.list()
    |> Enum.filter(fn pid ->
      try do
        :erlang.check_process_code(pid, module) == true
      catch
        :error, _ -> false
      end
    end)
  end

  defp unload_block_reason(id, module) do
    module
    |> lingering_pids()
    |> case do
      [] ->
        []

      pids ->
        [%{id: id, module: module, pids: pids}]
    end
  end

  defp unload_module(module) when is_atom(module) do
    _ = :code.soft_purge(module)
    _ = :code.purge(module)
    _ = :code.delete(module)
    :ok
  end

  defp normalize_diagnostics(diagnostics) do
    diagnostics
    |> List.wrap()
    |> Enum.map(fn
      %{message: message} when is_binary(message) -> message
      message when is_binary(message) -> message
      other -> inspect(other)
    end)
  end
end
