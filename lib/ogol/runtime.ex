defmodule Ogol.Runtime do
  @moduledoc """
  Public runtime boundary for compilation, artifact inspection, and machine interaction.

  Callers should use this module instead of reaching into leaf runtime
  implementation modules directly.
  """

  alias Ogol.Runtime.{Deployment, Target}
  alias Ogol.Session
  alias Ogol.Session.{State, Workspace}

  @type artifact_kind :: :hardware | :machine | :sequence | :topology
  @type event_payload :: map()
  @type event_meta :: map()

  @doc """
  Compile the current workspace artifact for the given kind and id.
  """
  @spec compile(:hardware | :machine | :sequence | :topology, String.t()) ::
          term()
  def compile(:hardware, id), do: compile(current_workspace(), :hardware, id)
  def compile(:machine, id), do: compile(current_workspace(), :machine, id)
  def compile(:sequence, id), do: compile(current_workspace(), :sequence, id)
  def compile(:topology, id), do: compile(current_workspace(), :topology, id)

  @spec compile(
          Workspace.t(),
          :hardware | :machine | :sequence | :topology,
          String.t()
        ) :: term()
  def compile(%Workspace{} = workspace, :hardware, id),
    do: Deployment.compile_hardware(workspace, id)

  def compile(%Workspace{} = workspace, :machine, id),
    do: Deployment.compile_machine(workspace, id)

  def compile(%Workspace{} = workspace, :sequence, id),
    do: Deployment.compile_sequence(workspace, id)

  def compile(%Workspace{} = workspace, :topology, id),
    do: Deployment.compile_topology(workspace, id)

  defdelegate artifact_id(kind, id), to: Deployment

  def machine_contract(module_name),
    do: Deployment.machine_contract(current_workspace(), module_name)

  def machine_contract(%Workspace{} = workspace, module_name),
    do: Deployment.machine_contract(workspace, module_name)

  defdelegate delete_artifact(kind, id), to: Deployment
  defdelegate reset(), to: Deployment
  defdelegate current(id), to: Deployment
  defdelegate current(kind, id), to: Deployment
  defdelegate status(id), to: Deployment
  defdelegate status(kind, id), to: Deployment
  defdelegate artifact_statuses(), to: Deployment
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

  defp current_workspace do
    Session.get_state()
    |> State.workspace()
  end
end
