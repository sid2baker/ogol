defmodule Ogol.Studio.RevisionStore do
  @moduledoc false

  use GenServer

  alias Ogol.Studio.Build
  alias Ogol.Studio.RevisionFile
  alias Ogol.Studio.Modules
  alias Ogol.Studio.TopologyRuntime
  alias Ogol.Studio.WorkspaceStore

  @table :ogol_studio_revisions
  @revisions_key :revisions
  @source_backed_compile_kinds [:driver, :hardware_config, :machine, :topology, :sequence]

  defmodule Revision do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            app_id: String.t(),
            title: String.t() | nil,
            topology_id: String.t(),
            hardware_config_id: String.t(),
            source: String.t(),
            source_digest: String.t(),
            deployed_at: DateTime.t()
          }

    defstruct [
      :id,
      :app_id,
      :title,
      :topology_id,
      :hardware_config_id,
      :source,
      :source_digest,
      :deployed_at
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def reset do
    :ets.delete_all_objects(@table)
    seed_defaults()
    :ok
  end

  def list_revisions do
    fetch(@revisions_key) || []
  end

  def fetch_revision(id) when is_binary(id) do
    list_revisions()
    |> Enum.find(&(&1.id == id))
  end

  def deploy_current(opts \\ []) do
    app_id = Keyword.get(opts, :app_id, "ogol")
    title = Keyword.get(opts, :title)
    revision_id = next_revision_id(list_revisions())
    deployed_at = DateTime.utc_now()

    with {:ok, source} <-
           RevisionFile.export_current(
             app_id: app_id,
             title: title,
             revision: revision_id,
             exported_at: DateTime.to_iso8601(deployed_at)
           ),
         {:ok, revision_file} <- RevisionFile.import(source),
         {:ok, topology_id} <- resolve_topology_id(revision_file, opts),
         {:ok, hardware_config_id} <- resolve_hardware_config_id(revision_file),
         :ok <- activate_revision(revision_file, topology_id) do
      revision = %Revision{
        id: revision_id,
        app_id: app_id,
        title: title,
        topology_id: topology_id,
        hardware_config_id: hardware_config_id,
        source: source,
        source_digest: Build.digest(source),
        deployed_at: deployed_at
      }

      put(@revisions_key, [revision | list_revisions()])

      {:ok, revision}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    seed_defaults()
    {:ok, %{}}
  end

  defp next_revision_id(revisions) do
    revisions
    |> Enum.map(&revision_number/1)
    |> Enum.max(fn -> 0 end)
    |> then(&"r#{&1 + 1}")
  end

  defp revision_number(%Revision{id: "r" <> rest}) do
    case Integer.parse(rest) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp revision_number(_other), do: 0

  defp resolve_topology_id(%RevisionFile{} = revision_file, opts) do
    requested_id =
      opts
      |> Keyword.get(:topology_id)
      |> normalize_requested_id()

    topology_id =
      requested_id ||
        default_topology_id(revision_file) ||
        revision_file
        |> RevisionFile.artifacts(:topology)
        |> Enum.map(& &1.id)
        |> Enum.sort()
        |> List.first()

    case topology_id do
      id when is_binary(id) ->
        case RevisionFile.artifact(revision_file, :topology, id) do
          nil -> {:error, {:unknown_topology, id}}
          _artifact -> {:ok, id}
        end

      nil ->
        {:error, :no_topology_available}
    end
  end

  defp resolve_hardware_config_id(%RevisionFile{} = revision_file) do
    case RevisionFile.artifacts(revision_file, :hardware_config) do
      [%RevisionFile.Artifact{model: %{id: id}}] when is_binary(id) ->
        {:ok, id}

      _other ->
        {:error, :no_hardware_config_available}
    end
  end

  defp default_topology_id(%RevisionFile{} = revision_file) do
    default_id = WorkspaceStore.topology_default_id()

    case RevisionFile.artifact(revision_file, :topology, default_id) do
      nil -> nil
      _artifact -> default_id
    end
  end

  defp activate_revision(%RevisionFile{} = revision_file, topology_id) do
    with :ok <- TopologyRuntime.stop_active(),
         :ok <- reset_runtime_modules(),
         :ok <- compile_revision(revision_file),
         {:ok, _result} <- WorkspaceStore.start_topology(topology_id) do
      _ =
        WorkspaceStore.put_loaded_revision(
          revision_file.app_id,
          revision_file.revision,
          RevisionFile.loaded_inventory(revision_file)
        )

      :ok
    end
  end

  defp reset_runtime_modules do
    case Modules.reset() do
      :ok -> :ok
      {:blocked, details} -> {:error, {:runtime_reset_blocked, details}}
    end
  end

  defp compile_revision(%RevisionFile{} = revision_file) do
    Enum.reduce_while(@source_backed_compile_kinds, :ok, fn kind, :ok ->
      revision_file
      |> RevisionFile.artifacts(kind)
      |> Enum.reduce_while(:ok, fn artifact, :ok ->
        case compile_artifact(artifact) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp compile_artifact(%RevisionFile.Artifact{kind: :driver, id: id, module: module}) do
    with {:ok, _draft} <- WorkspaceStore.compile_driver(id),
         {:ok, digest} <- current_workspace_digest(:driver, id),
         :ok <- ensure_runtime_loaded(:driver, id, module, digest) do
      :ok
    else
      {:error, :module_not_found, _draft} ->
        {:error, {:compile_failed, :driver, id, :module_not_found}}

      {:error, diagnostics, _draft} ->
        {:error, {:compile_failed, :driver, id, diagnostics}}

      {:error, _reason} = error ->
        error
    end
  end

  defp compile_artifact(%RevisionFile.Artifact{kind: :machine, id: id, module: module}) do
    with {:ok, _draft} <- WorkspaceStore.compile_machine(id),
         {:ok, digest} <- current_workspace_digest(:machine, id),
         :ok <- ensure_runtime_loaded(:machine, id, module, digest) do
      :ok
    else
      {:error, :module_not_found, _draft} ->
        {:error, {:compile_failed, :machine, id, :module_not_found}}

      {:error, diagnostics, _draft} ->
        {:error, {:compile_failed, :machine, id, diagnostics}}

      {:error, _reason} = error ->
        error
    end
  end

  defp compile_artifact(%RevisionFile.Artifact{kind: :hardware_config, id: id, module: module}) do
    with {:ok, _draft} <- WorkspaceStore.compile_hardware_config(),
         {:ok, digest} <- current_workspace_digest(:hardware_config, id),
         :ok <- ensure_runtime_loaded(:hardware_config, id, module, digest) do
      :ok
    else
      {:error, :module_not_found, _draft} ->
        {:error, {:compile_failed, :hardware_config, id, :module_not_found}}

      {:error, diagnostics, _draft} ->
        {:error, {:compile_failed, :hardware_config, id, diagnostics}}

      {:error, _reason} = error ->
        error
    end
  end

  defp compile_artifact(%RevisionFile.Artifact{kind: :topology, id: id, module: module}) do
    with {:ok, _draft} <- WorkspaceStore.compile_topology(id),
         {:ok, digest} <- current_workspace_digest(:topology, id),
         :ok <- ensure_runtime_loaded(:topology, id, module, digest) do
      :ok
    else
      {:error, :module_not_found, _draft} ->
        {:error, {:compile_failed, :topology, id, :module_not_found}}

      {:error, diagnostics, _draft} ->
        {:error, {:compile_failed, :topology, id, diagnostics}}

      {:error, _reason} = error ->
        error
    end
  end

  defp compile_artifact(%RevisionFile.Artifact{kind: :sequence, id: id, module: module}) do
    with {:ok, _draft} <- WorkspaceStore.compile_sequence(id),
         {:ok, digest} <- current_workspace_digest(:sequence, id),
         :ok <- ensure_runtime_loaded(:sequence, id, module, digest) do
      :ok
    else
      {:error, :module_not_found, _draft} ->
        {:error, {:compile_failed, :sequence, id, :module_not_found}}

      {:error, diagnostics, _draft} ->
        {:error, {:compile_failed, :sequence, id, diagnostics}}

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_runtime_loaded(kind, id, module, digest) do
    runtime_id = Modules.runtime_id(kind, id)

    case Modules.status(runtime_id) do
      {:ok, %{module: ^module, source_digest: ^digest, blocked_reason: nil}} ->
        :ok

      {:ok, %{blocked_reason: reason}} when not is_nil(reason) ->
        {:error, {:runtime_blocked, kind, id, reason}}

      {:ok, status} ->
        {:error, {:runtime_out_of_date, kind, id, status}}

      {:error, :not_found} ->
        {:error, {:runtime_not_loaded, kind, id}}
    end
  end

  defp current_workspace_digest(:driver, id) do
    case WorkspaceStore.fetch_driver(id) do
      %{source: source} when is_binary(source) -> {:ok, Build.digest(source)}
      _ -> {:error, {:missing_workspace_entry, :driver, id}}
    end
  end

  defp current_workspace_digest(:machine, id) do
    case WorkspaceStore.fetch_machine(id) do
      %{source: source} when is_binary(source) -> {:ok, Build.digest(source)}
      _ -> {:error, {:missing_workspace_entry, :machine, id}}
    end
  end

  defp current_workspace_digest(:hardware_config, _id) do
    case WorkspaceStore.fetch_hardware_config() do
      %{source: source} when is_binary(source) ->
        {:ok, Build.digest(source)}

      _ ->
        {:error,
         {:missing_workspace_entry, :hardware_config, WorkspaceStore.hardware_config_entry_id()}}
    end
  end

  defp current_workspace_digest(:topology, id) do
    case WorkspaceStore.fetch_topology(id) do
      %{source: source} when is_binary(source) -> {:ok, Build.digest(source)}
      _ -> {:error, {:missing_workspace_entry, :topology, id}}
    end
  end

  defp current_workspace_digest(:sequence, id) do
    case WorkspaceStore.fetch_sequence(id) do
      %{source: source} when is_binary(source) -> {:ok, Build.digest(source)}
      _ -> {:error, {:missing_workspace_entry, :sequence, id}}
    end
  end

  defp normalize_requested_id(nil), do: nil

  defp normalize_requested_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      id -> id
    end
  end

  defp seed_defaults do
    :ets.insert(@table, {@revisions_key, []})
  end

  defp fetch(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> nil
    end
  end

  defp put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end
end
