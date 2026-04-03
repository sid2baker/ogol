defmodule Ogol.Session.Revisions do
  @moduledoc false

  alias Ogol.Session
  alias Ogol.Session.RevisionFile
  alias Ogol.Session.RuntimeState
  alias Ogol.Studio.Build

  defmodule Revision do
    @moduledoc false

    @type t :: %__MODULE__{
            id: String.t(),
            app_id: String.t(),
            title: String.t() | nil,
            topology_id: String.t(),
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

    with {:ok, source} <- export_current_source(app_id, title, revision_id, saved_at),
         {:ok, revision_file} <- RevisionFile.import(source),
         {:ok, topology_id} <- resolve_topology_id(revision_file, opts),
         {:ok, source} <-
           export_current_source(
             app_id,
             title,
             revision_id,
             saved_at,
             revision_metadata(topology_id)
           ),
         {:ok, revision} <-
           write_revision_file(
             app_id,
             revision_id,
             source,
             title,
             topology_id,
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

    with {:ok, source} <- export_current_source(app_id, title, revision_id, saved_at),
         {:ok, revision_file} <- RevisionFile.import(source),
         {:ok, topology_id} <- resolve_topology_id(revision_file, opts),
         {:ok, source} <-
           export_current_source(
             app_id,
             title,
             revision_id,
             saved_at,
             revision_metadata(topology_id)
           ),
         {:ok, revision} <-
           write_revision_file(
             app_id,
             revision_id,
             source,
             title,
             topology_id,
             saved_at
           ),
         :ok <- start_live_runtime() do
      _ =
        Session.put_loaded_revision(
          revision_file.app_id,
          revision_file.revision,
          RevisionFile.loaded_inventory(revision_file)
        )

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
         {:ok, stat} <- File.stat(path) do
      %Revision{
        id: revision_file.revision,
        app_id: revision_file.app_id,
        title: revision_file.title,
        topology_id: topology_id,
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

    topology_ids =
      revision_file
      |> RevisionFile.artifacts(:topology)
      |> Enum.map(& &1.id)
      |> Enum.uniq()
      |> Enum.sort()

    topology_id =
      requested_id ||
        metadata_id(revision_file, :topology_id) ||
        case topology_ids do
          [id] -> id
          _other -> nil
        end

    case topology_id do
      id when is_binary(id) ->
        case RevisionFile.artifact(revision_file, :topology, id) do
          nil -> {:error, {:unknown_topology, id}}
          _artifact -> {:ok, id}
        end

      nil when length(topology_ids) > 1 ->
        {:error, {:multiple_topologies_not_supported, topology_ids}}

      nil ->
        {:error, :no_topology_available}
    end
  end

  defp export_current_source(app_id, title, revision_id, saved_at, metadata \\ nil) do
    RevisionFile.export_current(
      app_id: app_id,
      title: title,
      revision: revision_id,
      exported_at: DateTime.to_iso8601(saved_at),
      metadata: metadata
    )
  end

  defp revision_metadata(topology_id) do
    %{
      topology_id: topology_id
    }
  end

  defp start_live_runtime do
    case Session.set_desired_runtime({:running, :live}) do
      :ok ->
        case Session.runtime_state() do
          %RuntimeState{observed: {:running, :live}} ->
            :ok

          %RuntimeState{status: :failed, last_error: reason} ->
            {:error, reason}

          %RuntimeState{} = runtime_state ->
            {:error, {:runtime_not_realized, runtime_state}}
        end

      :error ->
        {:error, :runtime_intent_rejected}
    end
  end

  defp metadata_id(%RevisionFile{metadata: metadata}, key) when is_map(metadata) do
    case Map.get(metadata, key, Map.get(metadata, Atom.to_string(key))) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp metadata_id(%RevisionFile{}, _key), do: nil

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
