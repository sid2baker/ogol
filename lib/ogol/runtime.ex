defmodule Ogol.Runtime do
  @moduledoc """
  Public runtime boundary for compilation, deployment, and machine interaction.

  Callers should use this module instead of reaching into leaf runtime
  implementation modules directly.
  """

  alias Ogol.Runtime.{Deployment, Target}

  @type artifact_kind :: :driver | :hardware_config | :machine | :sequence | :topology
  @type event_payload :: map()
  @type event_meta :: map()

  @doc """
  Compile the current workspace artifact for the given kind and id.
  """
  @spec compile(:driver | :machine | :sequence | :topology, String.t()) :: term()
  def compile(:driver, id), do: compile_driver(id)
  def compile(:machine, id), do: compile_machine(id)
  def compile(:sequence, id), do: compile_sequence(id)
  def compile(:topology, id), do: compile_topology(id)

  @doc """
  Compile the current workspace hardware configuration.
  """
  @spec compile(:hardware_config) :: term()
  def compile(:hardware_config), do: compile_hardware_config()

  defdelegate artifact_id(kind, id), to: Deployment
  defdelegate compile_driver(id), to: Deployment
  defdelegate compile_machine(id), to: Deployment
  defdelegate compile_topology(id), to: Deployment
  defdelegate compile_sequence(id), to: Deployment
  defdelegate compile_hardware_config(), to: Deployment
  defdelegate machine_contract(module_name), to: Deployment
  defdelegate deploy_topology(id), to: Deployment
  defdelegate stop_topology(id), to: Deployment
  defdelegate stop_active(), to: Deployment
  defdelegate restart_active(), to: Deployment
  defdelegate reset(), to: Deployment
  defdelegate current(id), to: Deployment
  defdelegate current(kind, id), to: Deployment
  defdelegate status(id), to: Deployment
  defdelegate status(kind, id), to: Deployment
  defdelegate compiled_manifest(), to: Deployment
  defdelegate active_manifest(), to: Deployment
  defdelegate workspace_manifest(), to: Deployment
  defdelegate diff_workspace(), to: Deployment
  defdelegate apply_artifact(id, artifact), to: Deployment

  @spec request(GenServer.server(), atom(), event_payload(), event_meta(), timeout()) :: term()
  def request(server, name, data \\ %{}, meta \\ %{}, timeout \\ 5_000)
      when is_atom(name) and is_map(data) and is_map(meta) do
    :gen_statem.call(server, {:request, name, data, meta}, timeout)
  end

  @spec event(GenServer.server(), atom(), event_payload(), event_meta()) :: :ok
  def event(server, name, data \\ %{}, meta \\ %{})
      when is_atom(name) and is_map(data) and is_map(meta) do
    :gen_statem.cast(server, {:event, name, data, meta})
  end

  @spec hardware_event(GenServer.server(), atom(), event_payload(), event_meta()) :: :ok
  def hardware_event(server, name, data \\ %{}, meta \\ %{})
      when is_atom(name) and is_map(data) and is_map(meta) do
    send(server, {:ogol_hardware_event, name, data, meta})
    :ok
  end

  @doc """
  Invoke a public skill on a target machine runtime.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec invoke(pid() | atom(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(target, skill, args \\ %{}, opts \\ []) do
    meta = Keyword.get(opts, :meta, %{})
    timeout = Keyword.get(opts, :timeout, 5_000)

    with {:ok, %{pid: pid, module: target_module}} <- Target.resolve_machine_runtime(target) do
      case Enum.find(target_module.skills(), &(&1.name == skill)) do
        %Ogol.Machine.Skill{kind: :request} ->
          {:ok, request(pid, skill, args, meta, timeout)}

        %Ogol.Machine.Skill{kind: :event} ->
          :ok = event(pid, skill, args, meta)
          {:ok, :accepted}

        nil ->
          {:error, {:unknown_skill, skill}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, reason -> {:error, {:target_runtime_failure, reason}}
  end
end
