defmodule OgolWeb.Live.SessionSync do
  @moduledoc false

  alias Phoenix.Component
  alias Ogol.Session
  alias Ogol.Session.Data

  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    {data, client_id} =
      if Phoenix.LiveView.connected?(socket) do
        {data, client_id} = Session.register_client(self())
        :ok = Session.subscribe(:workspace)
        {data, client_id}
      else
        {Session.get_data(), nil}
      end

    socket
    |> put_data(data)
    |> put_client_id(client_id)
  end

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    put_data(socket, Session.get_data())
  end

  @spec apply_operations(Phoenix.LiveView.Socket.t(), [Data.operation()]) ::
          Phoenix.LiveView.Socket.t()
  def apply_operations(socket, operations) when is_list(operations) do
    data =
      Enum.reduce(operations, data(socket), fn operation, %Data{} = current_data ->
        {:ok, next_data, _reply} = Data.apply_operation(current_data, operation)
        next_data
      end)

    put_data(socket, data)
  end

  @spec ensure_entry(Phoenix.LiveView.Socket.t(), Data.kind(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def ensure_entry(socket, _kind, id) when id in [nil, ""], do: socket

  def ensure_entry(socket, kind, id) when is_atom(kind) and is_binary(id) do
    if fetch(socket, kind, id) do
      socket
    else
      refresh(socket)
    end
  end

  @spec data(term()) :: Data.t()
  def data(%{private: private} = source) when is_map(private) do
    Map.get(private, :session_data) || data(Map.get(source, :assigns, %{}))
  end

  def data(%{assigns: assigns}) when is_map(assigns) do
    data(assigns)
  end

  def data(%{session_data: %Data{} = data}) do
    data
  end

  def data(_source) do
    Session.get_data()
  end

  @spec loaded_revision(term()) :: Data.LoadedRevision.t() | nil
  def loaded_revision(source) do
    Data.loaded_revision(data(source))
  end

  @spec list_entries(term(), Data.kind()) :: [term()]
  def list_entries(source, kind) when is_atom(kind) do
    Data.list_entries(data(source), kind)
  end

  @spec fetch(term(), Data.kind(), String.t()) :: term() | nil
  def fetch(source, kind, id) when is_atom(kind) and is_binary(id) do
    Data.fetch(data(source), kind, id)
  end

  @spec fetch_hardware_config(term()) :: term() | nil
  def fetch_hardware_config(source) do
    fetch(source, :hardware_config, Session.hardware_config_entry_id())
  end

  @spec current_hardware_config(term()) :: term()
  def current_hardware_config(source) do
    Data.current_hardware_config(data(source))
  end

  defp put_client_id(socket, client_id) do
    put_in(socket.private[:session_client_id], client_id)
  end

  defp put_data(socket, %Data{} = data) do
    socket = put_in(socket.private[:session_data], data)
    Component.assign(socket, :session_data, data)
  end
end
