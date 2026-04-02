defmodule OgolWeb.Studio.Revision do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]

  alias Ogol.Session.Workspace
  alias OgolWeb.Live.SessionSync

  @readonly_title "Workspace Session"
  @readonly_message "Studio edits the shared workspace session directly."

  @spec subscribe(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def subscribe(socket) do
    socket
    |> SessionSync.attach()
    |> sync_session()
  end

  @spec apply_param(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def apply_param(socket, _params), do: sync_session(socket)

  @spec read_only?(Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def read_only?(%{assigns: assigns}), do: read_only?(assigns)
  def read_only?(%{studio_read_only?: value}) when is_boolean(value), do: value
  def read_only?(_other), do: false

  @spec sync_session(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def sync_session(socket) do
    {app_id, revision} =
      case SessionSync.loaded_revision(socket) do
        %Workspace.LoadedRevision{app_id: app_id, revision: revision} ->
          {app_id || "ogol", revision}

        _other ->
          {"ogol", nil}
      end

    socket
    |> assign(:revision_app_id, app_id)
    |> assign(:studio_selected_revision, revision)
    |> assign(:studio_read_only?, false)
  end

  @spec path_with_revision(String.t(), term()) :: String.t()
  def path_with_revision(path, _revision_source) when is_binary(path), do: path

  @spec readonly_title() :: String.t()
  def readonly_title, do: @readonly_title

  @spec readonly_message() :: String.t()
  def readonly_message, do: @readonly_message

  def apply_operations(socket, operations) when is_list(operations) do
    socket
    |> SessionSync.apply_operations(operations)
    |> sync_session()
  end
end
