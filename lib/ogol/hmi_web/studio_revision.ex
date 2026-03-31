defmodule Ogol.HMIWeb.StudioRevision do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Ogol.HMI.Bus
  alias Ogol.Studio.RevisionFile
  alias Ogol.Studio.RevisionStore
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
    params
    |> Map.get("revision")
    |> normalize_revision()
    |> load_workspace_revision()

    sync_session(socket)
  end

  @spec read_only?(Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def read_only?(%{assigns: assigns}), do: read_only?(assigns)
  def read_only?(%{studio_read_only?: value}) when is_boolean(value), do: value
  def read_only?(_other), do: false

  @spec sync_session(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def sync_session(socket) do
    revision =
      case WorkspaceStore.loaded_revision() do
        %WorkspaceStore.LoadedRevision{revision: revision} -> revision
        _other -> nil
      end

    socket
    |> assign(:studio_selected_revision, revision)
    |> assign(:studio_read_only?, false)
  end

  @spec path_with_revision(String.t(), Phoenix.LiveView.Socket.t() | map() | String.t() | nil) ::
          String.t()
  def path_with_revision(path, revision_source) when is_binary(path) do
    case revision_id(revision_source) do
      nil ->
        strip_revision(path)

      revision ->
        uri = URI.parse(path)
        query = uri.query |> decode_query() |> Map.put("revision", revision)
        %{uri | query: URI.encode_query(query)} |> URI.to_string()
    end
  end

  @spec readonly_title() :: String.t()
  def readonly_title, do: @readonly_title

  @spec readonly_message() :: String.t()
  def readonly_message, do: @readonly_message

  defp load_workspace_revision(nil) do
    _ = WorkspaceStore.set_loaded_revision_id(nil)
    :ok
  end

  defp load_workspace_revision(revision_id) do
    case WorkspaceStore.loaded_revision() do
      %WorkspaceStore.LoadedRevision{revision: ^revision_id} ->
        :ok

      _other ->
        with %RevisionStore.Revision{source: source} <- RevisionStore.fetch_revision(revision_id),
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

  defp revision_id(%{assigns: assigns}), do: revision_id(assigns)
  defp revision_id(%{studio_selected_revision: revision}), do: normalize_revision(revision)
  defp revision_id(revision), do: normalize_revision(revision)

  defp strip_revision(path) do
    uri = URI.parse(path)
    query = uri.query |> decode_query() |> Map.delete("revision")
    normalized_query = if map_size(query) == 0, do: nil, else: URI.encode_query(query)
    %{uri | query: normalized_query} |> URI.to_string()
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)
end
