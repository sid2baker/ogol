defmodule OgolWeb.Studio.Revision do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Ogol.Runtime.Bus
  alias Ogol.Studio.RevisionFile
  alias Ogol.Studio.Revisions
  alias Ogol.Studio.WorkspaceStore

  @readonly_title "Workspace Session"
  @readonly_message "Studio edits the shared workspace session directly."

  @spec subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe(socket) do
    if Phoenix.LiveView.connected?(socket) do
      :ok = Bus.subscribe(Bus.workspace_topic())
    end

    sync_session(socket)
  end

  @spec apply_param(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_param(socket, params) when is_map(params) do
    app_id =
      params
      |> Map.get("app_id", current_app_id(socket))
      |> normalize_app_id()

    socket = assign(socket, :revision_app_id, app_id)

    params
    |> Map.get("revision")
    |> normalize_revision()
    |> load_workspace_revision(app_id)

    sync_session(socket)
  end

  @spec read_only?(Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def read_only?(%{assigns: assigns}), do: read_only?(assigns)
  def read_only?(%{studio_read_only?: value}) when is_boolean(value), do: value
  def read_only?(_other), do: false

  @spec sync_session(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def sync_session(socket) do
    {app_id, revision} =
      case WorkspaceStore.loaded_revision() do
        %WorkspaceStore.LoadedRevision{app_id: app_id, revision: revision} ->
          {app_id || current_app_id(socket), revision}

        _other ->
          {current_app_id(socket), nil}
      end

    socket
    |> assign(:revision_app_id, app_id)
    |> assign(:studio_selected_revision, revision)
    |> assign(:studio_read_only?, false)
  end

  @spec path_with_revision(String.t(), Phoenix.LiveView.Socket.t() | map() | String.t() | nil) ::
          String.t()
  def path_with_revision(path, revision_source) when is_binary(path) do
    revision = revision_id(revision_source)
    app_id = revision_app_id(revision_source)

    query =
      path
      |> URI.parse()
      |> Map.get(:query)
      |> decode_query()
      |> maybe_put_query("revision", revision)
      |> maybe_put_query("app_id", app_id_param(app_id))

    normalized_query = if map_size(query) == 0, do: nil, else: URI.encode_query(query)
    path |> URI.parse() |> Map.put(:query, normalized_query) |> URI.to_string()
  end

  @spec readonly_title() :: String.t()
  def readonly_title, do: @readonly_title

  @spec readonly_message() :: String.t()
  def readonly_message, do: @readonly_message

  defp load_workspace_revision(nil, _app_id) do
    _ = WorkspaceStore.set_loaded_revision_id(nil)
    :ok
  end

  defp load_workspace_revision(revision_id, app_id) do
    case WorkspaceStore.loaded_revision() do
      %WorkspaceStore.LoadedRevision{app_id: ^app_id, revision: ^revision_id} ->
        :ok

      _other ->
        with %Revisions.Revision{source: source} <- Revisions.fetch_revision(app_id, revision_id),
             {:ok, _revision_file, _report} <-
               RevisionFile.load_into_workspace(source, force: true) do
          :ok
        else
          _ -> :ok
        end
    end
  end

  defp normalize_revision(nil), do: nil
  defp normalize_revision(""), do: nil
  defp normalize_revision(value) when is_binary(value), do: value
  defp normalize_revision(_other), do: nil

  defp normalize_app_id(nil), do: "ogol"

  defp normalize_app_id(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> "ogol"
      app_id -> app_id
    end
  end

  defp revision_id(%{assigns: assigns}), do: revision_id(assigns)
  defp revision_id(%{studio_selected_revision: revision}), do: normalize_revision(revision)
  defp revision_id(revision), do: normalize_revision(revision)

  defp revision_app_id(%{assigns: assigns}), do: revision_app_id(assigns)
  defp revision_app_id(%{revision_app_id: app_id}), do: normalize_app_id(app_id)
  defp revision_app_id(_other), do: nil

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp app_id_param("ogol"), do: nil
  defp app_id_param(app_id), do: app_id

  defp current_app_id(%{assigns: assigns}), do: current_app_id(assigns)

  defp current_app_id(%{revision_app_id: app_id}) when is_binary(app_id),
    do: normalize_app_id(app_id)

  defp current_app_id(_other), do: "ogol"
end
