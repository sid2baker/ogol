defmodule Ogol.Runtime.Deployment do
  @moduledoc false

  use GenServer

  alias Ogol.Driver.Parser, as: DriverParser
  alias Ogol.Hardware.Config
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.Machine.Contract, as: MachineContract
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Runtime.Bus
  alias Ogol.Runtime.Deployment.Manifest
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Build.Artifact
  alias Ogol.Studio.TopologyRuntime
  alias Ogol.Session.Manifest, as: WorkspaceManifest
  alias Ogol.Session
  alias Ogol.Session.Workspace.SourceDraft
  alias Ogol.Topology.Source, as: TopologySource

  @dispatch_timeout 15_000
  @source_backed_kinds [:driver, :hardware_config, :machine, :topology, :sequence]

  defmodule Manifest do
    @moduledoc false

    alias Ogol.Session.Manifest.Entry

    @type t :: %__MODULE__{
            deployment_id: String.t() | nil,
            topology_id: String.t() | nil,
            topology_module: module() | nil,
            started_at: integer() | nil,
            entries: [Entry.t()]
          }

    defstruct deployment_id: nil,
              topology_id: nil,
              topology_module: nil,
              started_at: nil,
              entries: []
  end

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

  defmodule OwnedProcess do
    @moduledoc false

    @type t :: %__MODULE__{
            pid: pid(),
            kind: atom(),
            module: module(),
            instance_id: term(),
            metadata: map()
          }

    defstruct [:pid, :kind, :module, :instance_id, metadata: %{}]
  end

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            next_deployment_number: pos_integer(),
            loaded_artifacts: %{optional({atom(), String.t()}) => LoadedArtifact.t()},
            active_manifest: Manifest.t() | nil,
            owned_processes: %{optional(pid()) => OwnedProcess.t()},
            monitors: %{optional(reference()) => pid()}
          }

    defstruct next_deployment_number: 1,
              loaded_artifacts: %{},
              active_manifest: nil,
              owned_processes: %{},
              monitors: %{}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def artifact_id(kind, id) when is_atom(kind), do: {kind, to_string(id)}

  def compile_driver(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_artifact, :driver, id}, @dispatch_timeout)
  end

  def compile_machine(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_artifact, :machine, id}, @dispatch_timeout)
  end

  def compile_topology(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_artifact, :topology, id}, @dispatch_timeout)
  end

  def compile_sequence(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_artifact, :sequence, id}, @dispatch_timeout)
  end

  def compile_hardware_config do
    GenServer.call(
      __MODULE__,
      {:compile_artifact, :hardware_config, Session.hardware_config_entry_id()},
      @dispatch_timeout
    )
  end

  def machine_contract(module_name) when is_binary(module_name) do
    GenServer.call(__MODULE__, {:machine_contract, module_name}, @dispatch_timeout)
  end

  def deploy_topology(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:deploy_topology, id}, @dispatch_timeout)
  end

  def stop_topology(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:stop_topology, id}, @dispatch_timeout)
  end

  def stop_active do
    GenServer.call(__MODULE__, :stop_active, @dispatch_timeout)
  end

  def restart_active do
    GenServer.call(__MODULE__, :restart_active, @dispatch_timeout)
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

  def compiled_manifest do
    GenServer.call(__MODULE__, :compiled_manifest)
  end

  def active_manifest do
    GenServer.call(__MODULE__, :active_manifest)
  end

  def workspace_manifest do
    WorkspaceManifest.current()
  end

  def diff_workspace do
    active_entries =
      case active_manifest() do
        %Manifest{entries: entries} -> entries
        nil -> []
      end

    WorkspaceManifest.diff(workspace_manifest(), active_entries)
  end

  def apply_artifact(id, %Artifact{} = artifact) do
    GenServer.call(__MODULE__, {:apply_artifact, id, artifact}, @dispatch_timeout)
  end

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:compile_artifact, kind, id}, _from, %State{} = state)
      when kind in @source_backed_kinds do
    {reply, next_state} = execute_compile_artifact(state, kind, id)
    broadcast_runtime_event({:compile_artifact, kind, id}, reply)
    {:reply, reply, next_state}
  end

  def handle_call({:deploy_topology, id}, _from, %State{} = state) do
    {reply, next_state} = execute_deploy_topology(state, id)
    broadcast_runtime_event({:deploy_topology, id}, reply)
    {:reply, reply, next_state}
  end

  def handle_call({:stop_topology, id}, _from, %State{} = state) do
    {reply, next_state} = execute_stop_topology(state, id)
    broadcast_runtime_event({:stop_topology, id}, reply)
    {:reply, reply, next_state}
  end

  def handle_call(:stop_active, _from, %State{} = state) do
    {reply, next_state} = stop_active_internal(state)
    broadcast_runtime_event(:stop_active, reply)
    {:reply, reply, next_state}
  end

  def handle_call(:restart_active, _from, %State{} = state) do
    {reply, next_state} = restart_active_internal(state)
    broadcast_runtime_event(:restart_active, reply)
    {:reply, reply, next_state}
  end

  def handle_call(:reset, _from, %State{} = state) do
    {reply, next_state} = reset_internal(state)
    broadcast_runtime_event(:reset_runtime, reply)
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

  def handle_call(:compiled_manifest, _from, %State{} = state) do
    entries =
      state.loaded_artifacts
      |> Map.values()
      |> Enum.filter(&(not is_nil(&1.source_digest)))
      |> Enum.map(&compiled_artifact_manifest_entry/1)
      |> Enum.sort_by(fn %{kind: kind, id: id} -> {kind, id} end)

    {:reply, entries, state}
  end

  def handle_call(:active_manifest, _from, %State{} = state) do
    {:reply, state.active_manifest, state}
  end

  def handle_call({:apply_artifact, id, %Artifact{} = artifact}, _from, %State{} = state) do
    {reply, next_state} = apply_artifact_internal(state, id, artifact)
    broadcast_runtime_event({:apply_artifact, id}, reply)
    {:reply, reply, next_state}
  end

  def handle_call({:machine_contract, module_name}, _from, %State{} = state)
      when is_binary(module_name) do
    {reply, next_state} = execute_machine_contract(state, module_name)
    {:reply, reply, next_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{} = state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {^pid, monitors} ->
        owned_process = Map.get(state.owned_processes, pid)

        next_state =
          state
          |> maybe_clear_active_manifest_for_owned_process(owned_process)
          |> clear_owned_process(pid)

        {:noreply, %State{next_state | monitors: monitors}}
    end
  end

  defp execute_compile_artifact(%State{} = state, :sequence, id) do
    case Session.fetch_sequence(id) do
      nil ->
        {{:error, :not_found}, state}

      draft ->
        execute_sequence_load(state, id, draft.source)
    end
  end

  defp execute_compile_artifact(%State{} = state, :topology, id) do
    case Session.fetch_topology(id) do
      nil ->
        {{:error, :not_found}, state}

      draft ->
        execute_topology_load(state, id, draft.source, Map.get(draft, :model))
    end
  end

  defp execute_compile_artifact(%State{} = state, kind, id) do
    case workspace_fetch(kind, id) do
      nil ->
        {{:error, :not_found}, state}

      %{source: source} = draft ->
        execute_compile_and_load(state, kind, id, source, Map.get(draft, :model))
    end
  end

  defp execute_deploy_topology(%State{} = state, id) do
    with {:ok, stopped_state} <- maybe_stop_conflicting_deployment(state, id),
         {:ok, loaded_state} <- compile_workspace_artifacts(stopped_state),
         %{source: source} = draft <- Session.fetch_topology(id),
         {:ok, module} <- topology_runtime_module(source, Map.get(draft, :model)),
         {:ok, topology_model} <- runtime_topology_model(module),
         :ok <- TopologyRuntime.preflight_start_loaded(module),
         {:ok, prepared_state, hardware_config} <-
           maybe_ensure_hardware_runtime(loaded_state, topology_model),
         {:ok, machine_state} <- ensure_machine_runtime_contexts(prepared_state, topology_model) do
      case TopologyRuntime.start_loaded(module, topology_model, hardware_config: hardware_config) do
        {:ok, %{module: ^module, pid: pid}} ->
          deployment_id = next_deployment_id(machine_state)
          started_at = DateTime.utc_now()
          manifest = WorkspaceManifest.current()

          active_manifest = %Manifest{
            deployment_id: deployment_id,
            started_at: started_at,
            entries: manifest,
            topology_id: id,
            topology_module: module
          }

          next_state =
            machine_state
            |> put_active_manifest(active_manifest)
            |> register_owned_process(%OwnedProcess{
              pid: pid,
              kind: :topology,
              module: module,
              instance_id: id,
              metadata: %{topology_id: id}
            })
            |> increment_deployment_generation()

          {{:ok, %{deployment_id: deployment_id, topology_id: id, module: module, pid: pid}},
           next_state}

        {:error, reason} ->
          {{:error, reason}, machine_state}
      end
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

  defp execute_stop_topology(%State{} = state, id) do
    case state.active_manifest do
      %Manifest{topology_id: ^id, topology_module: module} ->
        case TopologyRuntime.stop_loaded(module) do
          :ok ->
            {:ok, clear_active_manifest(state)}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      %Manifest{} ->
        {{:error, :different_topology_running}, state}

      nil ->
        {{:error, :not_running}, state}
    end
  end

  defp stop_active_internal(%State{} = state) do
    case state.active_manifest do
      nil ->
        {:ok, state}

      %Manifest{} = manifest ->
        case TopologyRuntime.stop_loaded(manifest.topology_module) do
          :ok -> {:ok, clear_active_manifest(state)}
          {:error, reason} -> {{:error, reason}, state}
        end
    end
  end

  defp restart_active_internal(%State{} = state) do
    case state.active_manifest do
      nil ->
        {{:error, :not_running}, state}

      %Manifest{topology_id: topology_id} ->
        case stop_active_internal(state) do
          {:ok, stopped_state} ->
            execute_deploy_topology(stopped_state, topology_id)

          {{:error, reason}, stopped_state} ->
            {{:error, reason}, stopped_state}
        end
    end
  end

  defp reset_internal(%State{} = state) do
    state =
      case stop_active_internal(state) do
        {:ok, next_state} -> next_state
        {{:error, _reason}, next_state} -> next_state
      end

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

        {:ok,
         %State{
           state
           | loaded_artifacts: %{},
             active_manifest: nil,
             owned_processes: %{},
             monitors: %{}
         }}

      blocked_modules ->
        {{:blocked, %{reason: :old_code_in_use, modules: blocked_modules}}, state}
    end
  end

  defp compile_workspace_artifacts(%State{} = state) do
    Enum.reduce_while(@source_backed_kinds, {:ok, state}, fn kind, {:ok, current_state} ->
      workspace_entries_for_kind(kind)
      |> Enum.reduce_while({:ok, current_state}, fn draft, {:ok, runtime_state} ->
        artifact_id = artifact_id(kind, draft.id)

        case execute_compile_artifact(runtime_state, kind, draft.id) do
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

  defp workspace_entries_for_kind(:driver), do: Session.list_drivers()
  defp workspace_entries_for_kind(:machine), do: Session.list_machines()
  defp workspace_entries_for_kind(:topology), do: Session.list_topologies()
  defp workspace_entries_for_kind(:sequence), do: Session.list_sequences()
  defp workspace_entries_for_kind(:hardware_config), do: Session.list_hardware_configs()

  defp maybe_stop_conflicting_deployment(%State{} = state, topology_id) do
    case state.active_manifest do
      nil ->
        {:ok, state}

      %Manifest{topology_id: ^topology_id, topology_module: module} ->
        case TopologyRuntime.stop_loaded(module) do
          :ok -> {:ok, clear_active_manifest(state)}
          {:error, reason} -> {:error, reason, state}
        end

      %Manifest{topology_id: active_topology_id} ->
        {:error, {:different_topology_running, active_topology_id}, state}
    end
  end

  defp execute_sequence_load(%State{} = state, id, source) do
    case build_sequence_artifact(state, id, source) do
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

  defp execute_topology_load(%State{} = state, id, source, model) do
    case ensure_topology_compile_context(state, source, model) do
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

  defp execute_machine_contract(%State{} = state, module_name) do
    case workspace_entry_by_module(:machine, module_name) do
      nil ->
        {{:error, :not_found}, state}

      draft ->
        case ensure_workspace_entry_current(state, :machine, draft) do
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

  defp maybe_ensure_hardware_runtime(%State{} = state, %{machines: machines})
       when is_list(machines) do
    if topology_requires_hardware?(machines) do
      with {:ok, runtime_state, module} <- ensure_hardware_runtime_loaded(state),
           {:ok, _runtime} <- ensure_hardware_runtime_ready(module),
           %Config{} = hardware_config <- Session.current_hardware_config() do
        {:ok, runtime_state, hardware_config}
      else
        {:blocked, _details, _runtime_state} = blocked -> blocked
        {:error, _reason, _runtime_state} = error -> error
        {:error, reason} -> {:error, {:hardware_activation_failed, reason}, state}
        nil -> {:error, {:hardware_activation_failed, :no_hardware_config}, state}
      end
    else
      {:ok, state, nil}
    end
  end

  defp maybe_ensure_hardware_runtime(%State{} = state, _topology_model), do: {:ok, state, nil}

  defp ensure_hardware_runtime_loaded(%State{} = state) do
    with {:ok, draft} <- fetch_hardware_config_draft(),
         artifact_key <- artifact_id(:hardware_config, draft.id) do
      draft_source_digest = Build.digest(draft.source)

      case fetch_loaded_artifact(state, artifact_key) do
        %LoadedArtifact{
          module: module,
          source_digest: source_digest,
          blocked_reason: nil
        }
        when is_atom(module) ->
          if source_digest == draft_source_digest do
            {:ok, state, module}
          else
            compile_hardware_runtime_module(state, draft.id)
          end

        _ ->
          compile_hardware_runtime_module(state, draft.id)
      end
    end
  end

  defp compile_hardware_runtime_module(%State{} = state, draft_id) do
    case execute_compile_artifact(state, :hardware_config, draft_id) do
      {{:ok, %{module: module}}, next_state} -> {:ok, next_state, module}
      {{:error, :module_not_found}, _next_state} -> {:error, :module_not_found, state}
      {{:error, status}, next_state} -> {:blocked, status, next_state}
    end
  end

  defp fetch_hardware_config_draft do
    case Session.fetch_hardware_config() do
      %SourceDraft{} = draft -> {:ok, draft}
      nil -> {:error, :no_hardware_config_available}
    end
  end

  defp ensure_hardware_runtime_ready(module) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:hardware_config_module_not_loaded, module}}

      not function_exported?(module, :ensure_ready, 0) ->
        {:error, {:hardware_config_module_missing_ensure_ready, module}}

      true ->
        module.ensure_ready()
    end
  end

  defp ensure_machine_runtime_contexts(%State{} = state, %{machines: machines})
       when is_list(machines) do
    machines
    |> Enum.map(&machine_module_reference/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, state}, fn module_reference, {:ok, current_state} ->
      case ensure_machine_runtime_current(current_state, module_reference) do
        {:ok, next_state} ->
          {:cont, {:ok, next_state}}

        {:blocked, details, next_state} ->
          {:halt, {:blocked, details, next_state}}

        {:error, reason, next_state} ->
          {:halt, {:error, reason, next_state}}
      end
    end)
  end

  defp ensure_machine_runtime_contexts(%State{} = state, _model), do: {:ok, state}

  defp ensure_machine_runtime_current(%State{} = state, module_reference) do
    {module_name, module} = machine_module_identity(module_reference)

    case machine_draft_for_module(module_reference) do
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
              compile_machine_runtime_module(state, module_name, draft.id)
            end

          _ ->
            compile_machine_runtime_module(state, module_name, draft.id)
        end
    end
  end

  defp compile_machine_runtime_module(%State{} = state, module_name, draft_id) do
    case execute_compile_artifact(state, :machine, draft_id) do
      {{:ok, _status}, next_state} ->
        {:ok, next_state}

      {{:error, %{} = status}, next_state} ->
        {:blocked, status, next_state}

      {{:error, :module_not_found}, next_state} ->
        {:error, {:machine_module_not_available, module_name}, next_state}
    end
  end

  defp build_artifact(:driver, id, source, _model) do
    with {:ok, module} <- DriverParser.module_from_source(source),
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

  defp build_artifact(:hardware_config, id, source, _model) do
    with {:ok, module} <- HardwareConfigSource.module_from_source(source),
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

  defp ensure_topology_compile_context(%State{} = state, source, model) do
    case topology_compile_projection(source, model) do
      {:ok, topology_model} ->
        case ensure_machine_runtime_contexts(state, topology_model) do
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

  defp build_sequence_artifact(%State{} = state, id, source) do
    with {:ok, parsed} <- SequenceSource.from_source(source),
         {:ok, prepared_state} <-
           ensure_sequence_runtime_context(state, parsed.topology_module_name),
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

  defp ensure_sequence_runtime_context(%State{} = state, topology_module_name)
       when is_binary(topology_module_name) do
    with {:ok, draft} <- fetch_sequence_topology_entry(topology_module_name),
         {:ok, topology_state} <- ensure_sequence_dependency_loaded(state, :topology, draft),
         {:ok, topology_model} <- topology_model_from_entry(draft, topology_module_name),
         {:ok, machine_state} <-
           ensure_sequence_machine_contexts(topology_state, topology_model.machines) do
      {:ok, machine_state}
    end
  end

  defp ensure_sequence_machine_contexts(%State{} = state, machines) when is_list(machines) do
    Enum.reduce_while(machines, {:ok, state}, fn machine, {:ok, current_state} ->
      case ensure_sequence_machine_context(current_state, Map.get(machine, :module_name)) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_sequence_machine_contexts(%State{} = state, _machines), do: {:ok, state}

  defp ensure_sequence_machine_context(%State{} = state, module_name)
       when is_binary(module_name) do
    with {:ok, draft} <- fetch_sequence_machine_entry(module_name),
         {:ok, next_state} <- ensure_sequence_dependency_loaded(state, :machine, draft) do
      {:ok, next_state}
    end
  end

  defp ensure_sequence_machine_context(%State{} = state, _module_name), do: {:ok, state}

  defp ensure_sequence_dependency_loaded(%State{} = state, kind, draft) do
    case ensure_workspace_entry_current(state, kind, draft) do
      {:ok, next_state, _module} ->
        {:ok, next_state}

      {:error, reason, _next_state} ->
        {:error, dependency_load_diagnostics(kind, draft.id, reason)}
    end
  end

  defp fetch_sequence_topology_entry(module_name) do
    case workspace_entry_by_module(:topology, module_name) do
      nil ->
        {:error,
         [
           "Sequence compile targets topology #{module_name}, but that topology is not present in the current workspace."
         ]}

      draft ->
        {:ok, draft}
    end
  end

  defp fetch_sequence_machine_entry(module_name) do
    case workspace_entry_by_module(:machine, module_name) do
      nil ->
        {:error,
         [
           "Sequence compile references machine module #{module_name}, but that machine is not present in the current workspace."
         ]}

      draft ->
        {:ok, draft}
    end
  end

  defp ensure_workspace_entry_current(%State{} = state, kind, %{id: id, source: source})
       when kind in @source_backed_kinds and is_binary(id) and is_binary(source) do
    source_digest = Build.digest(source)

    case fetch_loaded_artifact(state, artifact_id(kind, id)) do
      %LoadedArtifact{module: module, source_digest: ^source_digest, blocked_reason: nil}
      when is_atom(module) ->
        {:ok, state, module}

      _ ->
        compile_workspace_entry(state, kind, id)
    end
  end

  defp compile_workspace_entry(%State{} = state, kind, id) when kind in @source_backed_kinds do
    case execute_compile_artifact(state, kind, id) do
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

  defp workspace_entry_by_module(:machine, module_name) do
    Enum.find(Session.list_machines(), &(entry_module_name(:machine, &1) == module_name))
  end

  defp workspace_entry_by_module(:topology, module_name) do
    Enum.find(
      Session.list_topologies(),
      &(entry_module_name(:topology, &1) == module_name)
    )
  end

  defp workspace_entry_by_module(_kind, _module_name), do: nil

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

  defp compiled_artifact_manifest_entry(%LoadedArtifact{} = entry) do
    %WorkspaceManifest.Entry{
      kind: entry.kind,
      id: entry.artifact_id,
      artifact_name: entry.artifact_id,
      module: entry.module,
      source_digest: entry.source_digest,
      provenance: %{cell_id: entry.artifact_id}
    }
  end

  defp fetch_loaded_artifact(%State{} = state, id), do: Map.get(state.loaded_artifacts, id)

  defp put_loaded_artifact(%State{} = state, %LoadedArtifact{id: id} = entry) do
    put_in(state.loaded_artifacts[id], entry)
  end

  defp put_active_manifest(%State{} = state, %Manifest{} = manifest) do
    %State{state | active_manifest: manifest}
  end

  defp clear_active_manifest(%State{} = state) do
    %State{state | active_manifest: nil, owned_processes: %{}, monitors: %{}}
  end

  defp register_owned_process(%State{} = state, %OwnedProcess{pid: pid} = owned_process) do
    ref = Process.monitor(pid)

    state
    |> put_in([Access.key(:owned_processes), pid], owned_process)
    |> put_in([Access.key(:monitors), ref], pid)
  end

  defp clear_owned_process(%State{} = state, pid) when is_pid(pid) do
    %State{state | owned_processes: Map.delete(state.owned_processes, pid)}
  end

  defp maybe_clear_active_manifest_for_owned_process(
         %State{} = state,
         %OwnedProcess{kind: :topology}
       ) do
    case state.active_manifest do
      %Manifest{} -> clear_active_manifest(state)
      _ -> state
    end
  end

  defp maybe_clear_active_manifest_for_owned_process(%State{} = state, _owned_process), do: state

  defp increment_deployment_generation(%State{} = state) do
    %State{state | next_deployment_number: state.next_deployment_number + 1}
  end

  defp next_deployment_id(%State{} = state), do: "d#{state.next_deployment_number}"

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

  defp workspace_fetch(:driver, id), do: Session.fetch_driver(id)
  defp workspace_fetch(:machine, id), do: Session.fetch_machine(id)
  defp workspace_fetch(:topology, id), do: Session.fetch_topology(id)
  defp workspace_fetch(:sequence, id), do: Session.fetch_sequence(id)
  defp workspace_fetch(:hardware_config, _id), do: Session.fetch_hardware_config()

  defp machine_draft_for_module(module_name) when is_binary(module_name) do
    workspace_entry_by_module(:machine, module_name)
  end

  defp machine_draft_for_module(module) when is_atom(module) do
    machine_draft_for_module(Atom.to_string(module) |> String.trim_leading("Elixir."))
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
  defp humanize_kind(:hardware_config), do: "hardware config"
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

  defp broadcast_runtime_event(action, reply) do
    Bus.broadcast(Bus.workspace_topic(), {:runtime_updated, action, reply})
  end
end
