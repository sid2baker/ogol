defmodule Ogol.Studio.Revisions do
  @moduledoc false

  alias Ogol.Studio.Build
  alias Ogol.Studio.Modules
  alias Ogol.Studio.RevisionFile
  alias Ogol.Studio.RuntimeStore
  alias Ogol.Studio.TopologyRuntime
  alias Ogol.Studio.WorkspaceStore

  @source_backed_compile_kinds [:driver, :hardware_config, :machine, :topology, :sequence]

  defmodule Revision do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            app_id: String.t(),
            title: String.t() | nil,
            topology_id: String.t(),
            hardware_config_id: String.t(),
            path: String.t(),
            source: String.t(),
            source_digest: String.t(),
            saved_at: DateTime.t()
          }

    defstruct [
      :id,
      :app_id,
      :title,
      :topology_id,
      :hardware_config_id,
      :path,
      :source,
      :source_digest,
      :saved_at
    ]
  end

  def list_revisions(app_id \\ nil)

  def list_revisions(nil) do
    revisions_root()
    |> list_app_dirs()
    |> Enum.flat_map(&list_revisions_for_app_dir/1)
    |> Enum.sort_by(&revision_sort_key/1, :desc)
  end

  def list_revisions(app_id) when is_binary(app_id) do
    app_id
    |> revisions_dir()
    |> list_revisions_for_app_dir()
    |> Enum.sort_by(&revision_sort_key/1, :desc)
  end

  def fetch_revision(app_id, revision_id) when is_binary(app_id) and is_binary(revision_id) do
    app_id
    |> revision_path(revision_id)
    |> revision_from_path()
  end

  def save_current(opts \\ []) do
    app_id = Keyword.get(opts, :app_id, "ogol")
    title = Keyword.get(opts, :title)
    revision_id = Keyword.get(opts, :revision, next_revision_id(app_id))
    saved_at = DateTime.utc_now()

    with {:ok, source} <-
           RevisionFile.export_current(
             app_id: app_id,
             title: title,
             revision: revision_id,
             exported_at: DateTime.to_iso8601(saved_at)
           ),
         {:ok, revision_file} <- RevisionFile.import(source),
         {:ok, topology_id} <- resolve_topology_id(revision_file, opts),
         {:ok, hardware_config_id} <- resolve_hardware_config_id(revision_file),
         {:ok, revision} <-
           write_revision_file(
             app_id,
             revision_id,
             source,
             title,
             topology_id,
             hardware_config_id,
             saved_at
           ) do
      {:ok, revision}
    end
  end

  def deploy_current(opts \\ []) do
    app_id = Keyword.get(opts, :app_id, "ogol")
    title = Keyword.get(opts, :title)
    revision_id = next_revision_id(app_id)
    saved_at = DateTime.utc_now()

    with {:ok, source} <-
           RevisionFile.export_current(
             app_id: app_id,
             title: title,
             revision: revision_id,
             exported_at: DateTime.to_iso8601(saved_at)
           ),
         {:ok, revision_file} <- RevisionFile.import(source),
         {:ok, topology_id} <- resolve_topology_id(revision_file, opts),
         {:ok, hardware_config_id} <- resolve_hardware_config_id(revision_file),
         :ok <- activate_revision(revision_file, topology_id),
         {:ok, revision} <-
           write_revision_file(
             app_id,
             revision_id,
             source,
             title,
             topology_id,
             hardware_config_id,
             saved_at
           ) do
      {:ok, revision}
    end
  end

  def reset do
    case File.rm_rf(revisions_root()) do
      {:ok, _paths} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  def revisions_root do
    Application.get_env(:ogol, __MODULE__, [])
    |> Keyword.get(:root, default_revisions_root())
  end

  def revisions_dir(app_id) when is_binary(app_id) do
    Path.join(revisions_root(), sanitize_segment(app_id))
  end

  def revision_path(app_id, revision_id)
      when is_binary(app_id) and is_binary(revision_id) do
    Path.join(revisions_dir(app_id), "#{sanitize_segment(revision_id)}.ogol.ex")
  end

  defp write_revision_file(
         app_id,
         revision_id,
         source,
         title,
         topology_id,
         hardware_config_id,
         saved_at
       ) do
    path = revision_path(app_id, revision_id)

    with :ok <- File.mkdir_p(revisions_dir(app_id)),
         :ok <- File.write(path, source) do
      {:ok,
       %Revision{
         id: revision_id,
         app_id: app_id,
         title: title,
         topology_id: topology_id,
         hardware_config_id: hardware_config_id,
         path: path,
         source: source,
         source_digest: Build.digest(source),
         saved_at: saved_at
       }}
    else
      {:error, reason} -> {:error, {:revision_write_failed, reason}}
    end
  end

  defp list_app_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  defp list_revisions_for_app_dir(app_dir) do
    case File.ls(app_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".ogol.ex"))
        |> Enum.map(&Path.join(app_dir, &1))
        |> Enum.map(&revision_from_path/1)
        |> Enum.reject(&is_nil/1)

      {:error, :enoent} ->
        []

      {:error, _reason} ->
        []
    end
  end

  defp revision_from_path(path) do
    with {:ok, source} <- File.read(path),
         {:ok, revision_file} <- RevisionFile.import(source),
         {:ok, topology_id} <- resolve_topology_id(revision_file, []),
         {:ok, hardware_config_id} <- resolve_hardware_config_id(revision_file),
         {:ok, stat} <- File.stat(path) do
      %Revision{
        id: revision_file.revision,
        app_id: revision_file.app_id,
        title: revision_file.title,
        topology_id: topology_id,
        hardware_config_id: hardware_config_id,
        path: path,
        source: source,
        source_digest: Build.digest(source),
        saved_at: file_saved_at(stat)
      }
    else
      _ -> nil
    end
  end

  defp file_saved_at(%File.Stat{mtime: {{year, month, day}, {hour, minute, second}}}) do
    {:ok, naive} = NaiveDateTime.new(year, month, day, hour, minute, second)
    DateTime.from_naive!(naive, "Etc/UTC")
  end

  defp revision_sort_key(%Revision{} = revision) do
    {revision.app_id, revision_number(revision.id), revision.saved_at}
  end

  defp next_revision_id(app_id) do
    app_id
    |> list_revisions()
    |> Enum.map(&revision_number(&1.id))
    |> Enum.max(fn -> 0 end)
    |> then(&"r#{&1 + 1}")
  end

  defp revision_number("r" <> rest) do
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
         {:ok, _result} <- RuntimeStore.start_topology(topology_id) do
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
    with {:ok, _draft} <- RuntimeStore.compile_driver(id),
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
    with {:ok, _draft} <- RuntimeStore.compile_machine(id),
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
    with {:ok, _draft} <- RuntimeStore.compile_hardware_config(),
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
    with {:ok, _draft} <- RuntimeStore.compile_topology(id),
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
    with {:ok, _draft} <- RuntimeStore.compile_sequence(id),
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

  defp sanitize_segment(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/u, "_")
  end

  defp default_revisions_root do
    Path.expand("../../../var/revisions", __DIR__)
  end
end
