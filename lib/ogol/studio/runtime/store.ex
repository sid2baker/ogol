defmodule Ogol.Studio.RuntimeStore do
  @moduledoc false

  use GenServer

  alias Ogol.Driver.Parser, as: DriverParser
  alias Ogol.Runtime.Bus
  alias Ogol.Hardware.Config.Source, as: HardwareConfigSource
  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Sequence.Source, as: SequenceSource
  alias Ogol.Studio.Build
  alias Ogol.Studio.Build.Artifact
  alias Ogol.Studio.TopologyRuntime
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Studio.WorkspaceStore.HardwareConfigDraft
  alias Ogol.Studio.WorkspaceStore.LoadedRevision
  alias Ogol.Studio.WorkspaceStore.MachineDraft
  alias Ogol.Topology.Source, as: TopologySource

  @dispatch_timeout 15_000

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            runtime_entries: %{optional(term()) => RuntimeEntry.t()}
          }

    defstruct runtime_entries: %{}
  end

  defmodule RuntimeEntry do
    @moduledoc false

    @type t :: %__MODULE__{
            id: term(),
            module: module() | nil,
            source_digest: String.t() | nil,
            blocked_reason: term() | nil,
            lingering_pids: [pid()]
          }

    defstruct [
      :id,
      :module,
      :source_digest,
      :blocked_reason,
      lingering_pids: []
    ]
  end

  @type kind :: :driver | :machine | :topology | :sequence | :hardware_config

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def runtime_id(kind, id) when is_atom(kind), do: {kind, to_string(id)}

  def compile_driver(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_entry, :driver, id}, @dispatch_timeout)
  end

  def compile_machine(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_entry, :machine, id}, @dispatch_timeout)
  end

  def compile_topology(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_entry, :topology, id}, @dispatch_timeout)
  end

  def compile_sequence(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:compile_entry, :sequence, id}, @dispatch_timeout)
  end

  def compile_hardware_config do
    GenServer.call(
      __MODULE__,
      {:compile_entry, :hardware_config, WorkspaceStore.hardware_config_entry_id()},
      @dispatch_timeout
    )
  end

  def start_topology(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:start_topology, id}, @dispatch_timeout)
  end

  def ensure_hardware_runtime do
    GenServer.call(__MODULE__, :ensure_hardware_runtime, @dispatch_timeout)
  end

  def stop_topology(id) when is_binary(id) do
    GenServer.call(__MODULE__, {:stop_topology, id}, @dispatch_timeout)
  end

  def apply_artifact(id, %Artifact{} = artifact) do
    GenServer.call(__MODULE__, {:apply_artifact, id, artifact}, @dispatch_timeout)
  end

  def reset_runtime_modules do
    GenServer.call(__MODULE__, :reset_runtime_modules, @dispatch_timeout)
  end

  def fetch(id) do
    GenServer.call(__MODULE__, {:fetch, id})
  end

  def list do
    GenServer.call(__MODULE__, :list)
  end

  @impl true
  def init(_opts) do
    {:ok, %State{}}
  end

  @impl true
  def handle_call({:compile_entry, kind, id}, _from, %State{} = state)
      when kind in [:driver, :machine, :topology, :sequence, :hardware_config] do
    {reply, next_state} = execute_compile_entry(state, kind, id)
    broadcast_runtime_event({:compile_entry, kind, id}, reply)
    {:reply, reply, next_state}
  end

  def handle_call({:start_topology, id}, _from, %State{} = state) do
    {reply, next_state} = execute_start_topology(state, id)
    broadcast_runtime_event({:start_topology, id}, reply)
    {:reply, reply, next_state}
  end

  def handle_call(:ensure_hardware_runtime, _from, %State{} = state) do
    case ensure_hardware_runtime_activated(state) do
      {:ok, next_state} ->
        {:reply, :ok, next_state}

      {:blocked, details, next_state} ->
        {:reply, {:blocked, details}, next_state}

      {:error, reason, next_state} ->
        {:reply, {:error, reason}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_topology, id}, _from, %State{} = state) do
    {reply, next_state} = execute_stop_topology(state, id)
    broadcast_runtime_event({:stop_topology, id}, reply)
    {:reply, reply, next_state}
  end

  def handle_call({:apply_artifact, id, %Artifact{} = artifact}, _from, %State{} = state) do
    {reply, next_state} = apply_artifact_internal(state, id, artifact)
    broadcast_runtime_event({:apply_artifact, id}, reply)
    {:reply, reply, next_state}
  end

  def handle_call(:reset_runtime_modules, _from, %State{} = state) do
    {reply, next_state} = reset_runtime_modules_internal(state)
    broadcast_runtime_event(:reset_runtime_modules, reply)
    {:reply, reply, next_state}
  end

  def handle_call({:fetch, id}, _from, %State{} = state) do
    {:reply, fetch_runtime_entry(state, id), state}
  end

  def handle_call(:list, _from, %State{} = state) do
    entries =
      state.runtime_entries
      |> Map.values()
      |> Enum.sort_by(&inspect(&1.id))

    {:reply, entries, state}
  end

  defp execute_compile_entry(%State{} = state, :sequence, id) do
    case WorkspaceStore.fetch_sequence(id) do
      nil ->
        {:error, state}

      draft ->
        execute_sequence_compile(state, id, draft.source)
    end
  end

  defp execute_compile_entry(%State{} = state, kind, id) do
    case workspace_fetch(kind, id) do
      nil ->
        {:error, state}

      %{source: source} = draft ->
        execute_compile_and_load(state, kind, id, source, Map.get(draft, :model))
    end
  end

  defp execute_sequence_compile(%State{} = state, id, source) do
    case build_sequence_artifact(state, id, source) do
      {:ok, artifact} ->
        {apply_reply, next_state} =
          apply_artifact_internal(state, runtime_id(:sequence, id), artifact)

        diagnostics = compile_validation_diagnostics(:sequence, artifact.module)
        draft = store_compile_diagnostics(:sequence, id, diagnostics)
        reply = compile_reply(apply_reply, diagnostics, draft)
        {reply, next_state}

      {:error, :module_not_found} ->
        {{:error, :module_not_found, WorkspaceStore.fetch_sequence(id)}, state}

      {:error, diagnostics} ->
        draft = store_compile_diagnostics(:sequence, id, diagnostics)
        {{:error, diagnostics, draft}, state}
    end
  end

  defp execute_compile_and_load(%State{} = state, kind, id, source, model) do
    case build_artifact(kind, id, source, model) do
      {:ok, artifact} ->
        {apply_reply, next_state} = apply_artifact_internal(state, runtime_id(kind, id), artifact)
        diagnostics = compile_validation_diagnostics(kind, artifact.module)
        draft = store_compile_diagnostics(kind, id, diagnostics)
        reply = compile_reply(apply_reply, diagnostics, draft)
        {reply, next_state}

      {:error, :module_not_found} ->
        {{:error, :module_not_found, workspace_fetch(kind, id)}, state}

      {:error, diagnostics} ->
        draft = store_compile_diagnostics(kind, id, diagnostics)
        {{:error, diagnostics, draft}, state}
    end
  end

  defp execute_start_topology(%State{} = state, id) do
    case WorkspaceStore.fetch_topology(id) do
      %{source: source} = draft ->
        execute_start_topology_runtime(state, id, source, Map.get(draft, :model))

      nil ->
        {:error, state}
    end
  end

  defp execute_start_topology_runtime(%State{} = state, id, source, model) do
    with {:ok, module} <- topology_runtime_module(source, model),
         :ok <- ensure_runtime_module_current(state, :topology, id, source, module),
         {:ok, topology_model} <- runtime_topology_model(module),
         :ok <- TopologyRuntime.preflight_start_loaded(module),
         {:ok, hardware_state, hardware_config} <-
           maybe_ensure_hardware_runtime(state, topology_model) do
      case ensure_machine_runtime_contexts(hardware_state, topology_model) do
        {:ok, machine_state} ->
          case TopologyRuntime.start_loaded(module, topology_model,
                 hardware_config: hardware_config
               ) do
            {:ok, %{module: ^module, pid: pid}} ->
              {{:ok, %{module: module, pid: pid}}, machine_state}

            {:error, _reason} = error ->
              {error, machine_state}
          end

        {:blocked, details, machine_state} ->
          {{:blocked, details}, machine_state}

        {:error, reason, machine_state} ->
          {{:error, reason}, machine_state}
      end
    else
      {:blocked, details, next_state} ->
        {{:blocked, details}, next_state}

      {:error, reason, next_state} ->
        {{:error, reason}, next_state}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp execute_stop_topology(%State{} = state, id) do
    case WorkspaceStore.fetch_topology(id) do
      %{source: source} = draft ->
        reply =
          with {:ok, module} <- topology_runtime_module(source, Map.get(draft, :model)) do
            TopologyRuntime.stop_loaded(module)
          else
            {:error, :module_not_found} -> {:error, :module_not_found}
            {:error, _reason} = error -> error
          end

        {reply, state}

      nil ->
        {:error, state}
    end
  end

  defp ensure_hardware_runtime_activated(%State{} = state) do
    with {:ok, draft} <- fetch_hardware_config_draft(),
         {:ok, runtime_state, module} <- ensure_hardware_runtime_current(state, draft),
         {:ok, _runtime} <- ensure_hardware_runtime_ready(draft, module) do
      {:ok, runtime_state}
    else
      {:blocked, _details, _runtime_state} = blocked ->
        blocked

      {:error, _reason, _runtime_state} = error ->
        error

      {:error, reason} ->
        {:error, {:hardware_activation_failed, reason}, state}
    end
  end

  defp fetch_hardware_config_draft do
    case WorkspaceStore.fetch_hardware_config() do
      %HardwareConfigDraft{} = draft -> {:ok, draft}
      nil -> {:error, :no_hardware_config_available}
    end
  end

  defp ensure_hardware_runtime_current(%State{} = state, %HardwareConfigDraft{} = draft) do
    with {:ok, module} <- HardwareConfigSource.module_from_source(draft.source) do
      case ensure_runtime_module_current(
             state,
             :hardware_config,
             draft.id,
             draft.source,
             module
           ) do
        :ok ->
          {:ok, state, module}

        {:error, {:module_not_current, :hardware_config, _id}} ->
          compile_hardware_runtime(state, draft)

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, :module_not_found} ->
        {:error, :module_not_found, state}
    end
  end

  defp compile_hardware_runtime(%State{} = state, %HardwareConfigDraft{} = draft) do
    case build_artifact(:hardware_config, draft.id, draft.source, draft.model) do
      {:ok, artifact} ->
        {apply_reply, next_state} =
          apply_artifact_internal(state, runtime_id(:hardware_config, draft.id), artifact)

        _draft = store_compile_diagnostics(:hardware_config, draft.id, [])

        case apply_reply do
          {:ok, _result} ->
            {:ok, next_state, artifact.module}

          {:blocked, %{module: blocked_module, pids: pids}} ->
            {:blocked, %{reason: :old_code_in_use, module: blocked_module, pids: pids},
             next_state}

          {:error, reason} ->
            {:error, {:hardware_config_apply_failed, draft.id, reason}, next_state}
        end

      {:error, diagnostics} when is_list(diagnostics) ->
        _draft = store_compile_diagnostics(:hardware_config, draft.id, diagnostics)
        {:error, {:hardware_config_build_failed, draft.id, diagnostics}, state}

      {:error, :module_not_found} ->
        {:error, {:hardware_config_module_not_available, draft.id}, state}
    end
  end

  defp ensure_hardware_runtime_ready(%HardwareConfigDraft{} = draft, module)
       when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:hardware_config_module_not_loaded, draft.id, module}}

      not function_exported?(module, :ensure_ready, 0) ->
        {:error, {:hardware_config_module_missing_ensure_ready, draft.id, module}}

      true ->
        module.ensure_ready()
    end
  end

  defp build_artifact(:driver, id, source, _model) do
    with {:ok, module} <- DriverParser.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} -> {:error, :module_not_found}
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:machine, id, source, _model) do
    with {:ok, module} <- MachineSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} -> {:error, :module_not_found}
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:topology, id, source, %{module_name: module_name})
       when is_binary(module_name) do
    with {:ok, artifact} <- Build.build(id, TopologySource.module_from_name!(module_name), source) do
      {:ok, artifact}
    else
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:topology, id, source, _model) do
    with {:ok, module} <- TopologySource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} -> {:error, :module_not_found}
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_artifact(:hardware_config, id, source, _model) do
    with {:ok, module} <- HardwareConfigSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} -> {:error, :module_not_found}
      {:error, %{diagnostics: diagnostics}} -> {:error, diagnostics}
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [inspect(reason)]}
    end
  end

  defp build_sequence_artifact(%State{} = state, id, source) do
    with {:ok, parsed} <- SequenceSource.from_source(source),
         :ok <- ensure_sequence_runtime_context(state, parsed.topology_module_name),
         {:ok, module} <- SequenceSource.module_from_source(source),
         {:ok, artifact} <- Build.build(id, module, source) do
      {:ok, artifact}
    else
      {:error, :module_not_found} ->
        {:error, :module_not_found}

      {:error, diagnostics} when is_list(diagnostics) ->
        {:error, diagnostics}

      {:error, %{diagnostics: diagnostics}} ->
        {:error, diagnostics}

      {:error, reason} ->
        {:error, [inspect(reason)]}
    end
  end

  defp compile_validation_diagnostics(:sequence, module) when is_atom(module) do
    if function_exported?(module, :__ogol_sequence__, 0) do
      []
    else
      ["sequence source did not expose `__ogol_sequence__/0` after compile"]
    end
  end

  defp compile_validation_diagnostics(_kind, _module), do: []

  defp ensure_sequence_runtime_context(%State{} = state, topology_module_name)
       when is_binary(topology_module_name) do
    with {:ok, draft} <- fetch_sequence_topology_entry(topology_module_name),
         :ok <-
           ensure_sequence_runtime_module_current(
             state,
             :topology,
             draft.id,
             draft.source,
             topology_module_name
           ),
         {:ok, topology_model} <- topology_model_from_entry(draft, topology_module_name),
         :ok <- ensure_sequence_machine_contexts(state, topology_model.machines) do
      :ok
    end
  end

  defp ensure_sequence_machine_contexts(%State{} = state, machines) when is_list(machines) do
    Enum.reduce_while(machines, :ok, fn machine, :ok ->
      case ensure_sequence_machine_context(state, Map.get(machine, :module_name)) do
        :ok -> {:cont, :ok}
        {:error, _diagnostics} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_sequence_machine_contexts(_state, _machines), do: :ok

  defp ensure_sequence_machine_context(%State{} = state, module_name)
       when is_binary(module_name) do
    with {:ok, draft} <- fetch_sequence_machine_entry(module_name),
         :ok <-
           ensure_sequence_runtime_module_current(
             state,
             :machine,
             draft.id,
             draft.source,
             module_name
           ) do
      :ok
    end
  end

  defp fetch_sequence_topology_entry(module_name) do
    case Enum.find(
           WorkspaceStore.list_topologies(),
           &(entry_module_name(:topology, &1) == module_name)
         ) do
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
    case Enum.find(
           WorkspaceStore.list_machines(),
           &(entry_module_name(:machine, &1) == module_name)
         ) do
      nil ->
        {:error,
         [
           "Sequence compile references machine module #{module_name}, but that machine is not present in the current workspace."
         ]}

      draft ->
        {:ok, draft}
    end
  end

  defp ensure_sequence_runtime_module_current(%State{} = state, kind, id, source, module_name)
       when is_binary(id) and is_binary(source) and is_binary(module_name) do
    expected_module = SequenceSource.module_from_name!(module_name)
    expected_digest = Build.digest(source)
    runtime_id = runtime_id(kind, id)

    case fetch_runtime_entry(state, runtime_id) do
      %RuntimeEntry{
        module: ^expected_module,
        source_digest: ^expected_digest,
        blocked_reason: nil
      } ->
        :ok

      %RuntimeEntry{blocked_reason: reason} when not is_nil(reason) ->
        {:error, ["#{humanize_kind(kind)} #{id} is blocked in the runtime: #{inspect(reason)}"]}

      _ ->
        {:error, ["Compile #{humanize_kind(kind)} #{id} before compiling this sequence."]}
    end
  end

  defp topology_runtime_module(_source, %{module_name: module_name})
       when is_binary(module_name) do
    {:ok, TopologySource.module_from_name!(module_name)}
  end

  defp topology_runtime_module(source, _model) when is_binary(source) do
    TopologySource.module_from_source(source)
  end

  defp ensure_runtime_module_current(%State{} = state, kind, id, source, module)
       when is_atom(kind) and is_binary(id) and is_binary(source) and is_atom(module) do
    source_digest = Build.digest(source)

    case fetch_runtime_entry(state, runtime_id(kind, id)) do
      %RuntimeEntry{module: ^module, source_digest: ^source_digest, blocked_reason: nil} ->
        :ok

      %RuntimeEntry{blocked_reason: reason} when not is_nil(reason) ->
        {:error, {:module_blocked, kind, id, reason}}

      _ ->
        {:error, {:module_not_current, kind, id}}
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

        {:blocked, _blocked, _next_state} = blocked ->
          {:halt, blocked}

        {:error, _reason, _next_state} = error ->
          {:halt, error}
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

      %MachineDraft{} = draft ->
        source_digest = Build.digest(draft.source)
        runtime_id = runtime_id(:machine, draft.id)

        case fetch_runtime_entry(state, runtime_id) do
          %RuntimeEntry{module: ^module, source_digest: ^source_digest, blocked_reason: nil} ->
            {:ok, state}

          _entry ->
            compile_machine_runtime(state, draft, module_name)
        end
    end
  end

  defp compile_machine_runtime(%State{} = state, %MachineDraft{} = draft, module_name) do
    case build_artifact(:machine, draft.id, draft.source, draft.model) do
      {:ok, artifact} ->
        {apply_reply, next_state} =
          apply_artifact_internal(state, runtime_id(:machine, draft.id), artifact)

        _draft = store_compile_diagnostics(:machine, draft.id, [])

        case apply_reply do
          {:ok, _result} ->
            {:ok, next_state}

          {:blocked, %{module: blocked_module, pids: pids}} ->
            {:blocked, %{reason: :old_code_in_use, module: blocked_module, pids: pids},
             next_state}

          {:error, reason} ->
            {:error, {:machine_apply_failed, draft.id, reason}, next_state}
        end

      {:error, diagnostics} when is_list(diagnostics) ->
        _draft = store_compile_diagnostics(:machine, draft.id, diagnostics)
        {:error, {:machine_build_failed, draft.id, diagnostics}, state}

      {:error, :module_not_found} ->
        {:error, {:machine_module_not_available, module_name}, state}
    end
  end

  defp machine_draft_for_module(module_name) when is_binary(module_name) do
    WorkspaceStore.list_machines()
    |> Enum.find(fn draft ->
      case draft do
        %{model: %{module_name: ^module_name}} -> true
        _ -> false
      end
    end)
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

  defp humanize_kind(:machine), do: "machine"
  defp humanize_kind(:topology), do: "topology"
  defp humanize_kind(:sequence), do: "sequence"
  defp humanize_kind(:hardware_config), do: "hardware config"
  defp humanize_kind(kind), do: to_string(kind)

  defp runtime_topology_model(module) when is_atom(module) do
    if function_exported?(module, :__ogol_topology__, 0) do
      {:ok, apply(module, :__ogol_topology__, [])}
    else
      {:error, :topology_model_not_available}
    end
  end

  defp maybe_ensure_hardware_runtime(%State{} = state, %{machines: machines})
       when is_list(machines) do
    if topology_requires_hardware?(machines) do
      with {:ok, next_state} <- ensure_hardware_runtime_activated(state),
           %Ogol.Hardware.Config{} = hardware_config <- WorkspaceStore.current_hardware_config() do
        {:ok, next_state, hardware_config}
      else
        {:ok, _next_state} -> {:error, {:hardware_activation_failed, :no_hardware_config}, state}
        {:blocked, _details, _next_state} = blocked -> blocked
        {:error, _reason, _next_state} = error -> error
        {:error, _reason} = error -> error
        nil -> {:error, {:hardware_activation_failed, :no_hardware_config}, state}
      end
    else
      {:ok, state, nil}
    end
  end

  defp maybe_ensure_hardware_runtime(%State{} = state, _topology_model), do: {:ok, state, nil}

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

  defp apply_artifact_internal(%State{} = state, id, %Artifact{} = artifact) do
    entry = fetch_runtime_entry(state, id) || %RuntimeEntry{id: id}

    cond do
      not is_nil(entry.module) and entry.module != artifact.module ->
        next_state =
          state
          |> runtime_put(%{
            entry
            | blocked_reason: {:module_mismatch, entry.module, artifact.module}
          })

        {{:error, {:module_mismatch, entry.module, artifact.module}}, next_state}

      old_code?(artifact.module) and not :code.soft_purge(artifact.module) ->
        lingering_pids = lingering_pids(artifact.module)

        next_state =
          state
          |> runtime_put(%{
            entry
            | blocked_reason: :old_code_in_use,
              lingering_pids: lingering_pids
          })

        {{:blocked, %{reason: :old_code_in_use, module: artifact.module, pids: lingering_pids}},
         next_state}

      true ->
        case :code.load_binary(
               artifact.module,
               String.to_charlist(Atom.to_string(artifact.module)),
               artifact.beam
             ) do
          {:module, module} ->
            next_state =
              state
              |> runtime_put(%{
                entry
                | module: module,
                  source_digest: artifact.source_digest,
                  blocked_reason: nil,
                  lingering_pids: []
              })

            {{:ok, %{id: id, module: module, status: :applied}}, next_state}

          {:error, reason} ->
            next_state = state |> runtime_put(%{entry | blocked_reason: reason})
            {{:error, reason}, next_state}
        end
    end
  end

  defp reset_runtime_modules_internal(%State{} = state) do
    blocked =
      Enum.flat_map(Map.values(state.runtime_entries), fn
        %RuntimeEntry{module: module, id: id} when is_atom(module) ->
          unload_block_reason(id, module)

        _entry ->
          []
      end)

    case blocked do
      [] ->
        Enum.each(Map.values(state.runtime_entries), fn
          %RuntimeEntry{module: module} when is_atom(module) -> unload_module(module)
          _entry -> :ok
        end)

        {:ok, %State{state | runtime_entries: %{}}}

      blocked_modules ->
        {{:blocked, %{reason: :old_code_in_use, modules: blocked_modules}}, state}
    end
  end

  defp workspace_fetch(:driver, id), do: WorkspaceStore.fetch_driver(id)
  defp workspace_fetch(:machine, id), do: WorkspaceStore.fetch_machine(id)
  defp workspace_fetch(:topology, id), do: WorkspaceStore.fetch_topology(id)
  defp workspace_fetch(:sequence, id), do: WorkspaceStore.fetch_sequence(id)
  defp workspace_fetch(:hardware_config, _id), do: WorkspaceStore.fetch_hardware_config()

  defp store_compile_diagnostics(kind, id, diagnostics) do
    WorkspaceStore.record_compile(kind, id, diagnostics)
  end

  defp compile_reply({:ok, _result}, [], draft), do: {:ok, draft}
  defp compile_reply({:ok, _result}, diagnostics, draft), do: {:error, diagnostics, draft}
  defp compile_reply({:blocked, _blocked}, _diagnostics, draft), do: {:ok, draft}
  defp compile_reply({:error, _reason}, _diagnostics, draft), do: {:ok, draft}

  defp runtime_put(%State{} = state, %RuntimeEntry{id: id} = entry) do
    put_in(state.runtime_entries[id], entry)
  end

  defp fetch_runtime_entry(%State{} = state, id) do
    Map.get(state.runtime_entries, id)
  end

  defp broadcast_runtime_event(operation, reply) do
    Bus.broadcast(
      Bus.workspace_topic(),
      {:workspace_updated, operation, reply, workspace_session()}
    )
  end

  defp workspace_session do
    case WorkspaceStore.loaded_revision() do
      %LoadedRevision{} = loaded_revision ->
        %{
          app_id: loaded_revision.app_id,
          revision: loaded_revision.revision,
          inventory: loaded_revision.inventory
        }

      _other ->
        %{app_id: nil, revision: nil, inventory: []}
    end
  end

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
end
