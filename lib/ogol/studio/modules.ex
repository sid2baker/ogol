defmodule Ogol.Studio.Modules do
  @moduledoc false

  use GenServer

  alias Ogol.Studio.Build.Artifact
  alias Ogol.Studio.ModuleStatusStore
  alias Ogol.Studio.ModuleStatusStore.Entry

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec apply(term(), Artifact.t()) ::
          {:ok, %{id: term(), module: module(), status: :applied}}
          | {:blocked, %{reason: :old_code_in_use, module: module(), pids: [pid()]}}
          | {:error, term()}
  def apply(id, %Artifact{} = artifact) do
    ModuleStatusStore.ensure_started()
    GenServer.call(__MODULE__, {:apply, id, artifact})
  end

  @spec current(term()) :: {:ok, module()} | {:error, :not_found}
  def current(id) do
    case ModuleStatusStore.fetch(id) do
      %Entry{module: module} when is_atom(module) -> {:ok, module}
      _ -> {:error, :not_found}
    end
  end

  @spec status(term()) ::
          {:ok,
           %{
             module: module() | nil,
             apply_state: :draft | :built | :applied | :blocked,
             source_digest: String.t() | nil,
             built_source_digest: String.t() | nil,
             old_code: boolean(),
             blocked_reason: term() | nil,
             lingering_pids: [pid()],
             last_build_at: DateTime.t() | nil,
             last_apply_at: DateTime.t() | nil
           }}
          | {:error, :not_found}
  def status(id) do
    case ModuleStatusStore.fetch(id) do
      %Entry{} = entry ->
        {:ok,
         %{
           module: entry.module,
           apply_state: entry.apply_state,
           source_digest: entry.source_digest,
           built_source_digest: entry.built_source_digest,
           old_code: old_code?(entry.module),
           blocked_reason: entry.blocked_reason,
           lingering_pids: entry.lingering_pids,
           last_build_at: entry.last_build_at,
           last_apply_at: entry.last_apply_at
         }}

      nil ->
        {:error, :not_found}
    end
  end

  @impl true
  def init(_opts) do
    ModuleStatusStore.ensure_started()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:apply, id, %Artifact{} = artifact}, _from, state) do
    entry = ModuleStatusStore.fetch(id) || %Entry{id: id}

    reply =
      cond do
        not is_nil(entry.module) and entry.module != artifact.module ->
          ModuleStatusStore.mark_apply_error(
            id,
            {:module_mismatch, entry.module, artifact.module}
          )

          {:error, {:module_mismatch, entry.module, artifact.module}}

        old_code?(artifact.module) and not :code.soft_purge(artifact.module) ->
          lingering_pids = lingering_pids(artifact.module)
          ModuleStatusStore.mark_blocked(id, lingering_pids)

          {:blocked,
           %{
             reason: :old_code_in_use,
             module: artifact.module,
             pids: lingering_pids
           }}

        true ->
          case :code.load_binary(
                 artifact.module,
                 String.to_charlist(Atom.to_string(artifact.module)),
                 artifact.beam
               ) do
            {:module, module} ->
              ModuleStatusStore.mark_applied(id, module, artifact.source_digest)
              {:ok, %{id: id, module: module, status: :applied}}

            {:error, reason} ->
              ModuleStatusStore.mark_apply_error(id, reason)
              {:error, reason}
          end
      end

    {:reply, reply, state}
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
end
