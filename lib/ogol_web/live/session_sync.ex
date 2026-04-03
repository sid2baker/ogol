defmodule OgolWeb.Live.SessionSync do
  @moduledoc false

  alias Phoenix.Component
  alias Ogol.Session
  alias Ogol.Session.{State, Workspace}

  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    {session_state, client_id} =
      if Phoenix.LiveView.connected?(socket) do
        {session_state, client_id} = Session.register_client(self())
        :ok = Session.subscribe(:workspace)
        {session_state, client_id}
      else
        {Session.get_state(), nil}
      end

    socket
    |> put_state(session_state)
    |> put_client_id(client_id)
  end

  @spec refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh(socket) do
    put_state(socket, Session.get_state())
  end

  @spec apply_operations(Phoenix.LiveView.Socket.t(), [State.operation()]) ::
          Phoenix.LiveView.Socket.t()
  def apply_operations(socket, operations) when is_list(operations) do
    session_state =
      Enum.reduce(operations, state(socket), fn operation, %State{} = current_state ->
        {:ok, next_state, _reply, _accepted_operations, _actions} =
          State.apply_operation(current_state, operation)

        next_state
      end)

    put_state(socket, session_state)
  end

  @spec ensure_entry(Phoenix.LiveView.Socket.t(), State.kind(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def ensure_entry(socket, _kind, id) when id in [nil, ""], do: socket

  def ensure_entry(socket, kind, id) when is_atom(kind) and is_binary(id) do
    if fetch(socket, kind, id) do
      socket
    else
      refresh(socket)
    end
  end

  @spec state(term()) :: State.t()
  def state(%{private: private} = source) when is_map(private) do
    Map.get(private, :session_state) || state(Map.get(source, :assigns, %{}))
  end

  def state(%{assigns: assigns}) when is_map(assigns) do
    state(assigns)
  end

  def state(%{session_state: %State{} = session_state}) do
    session_state
  end

  def state(_source) do
    Session.get_state()
  end

  @spec loaded_revision(term()) :: Workspace.LoadedRevision.t() | nil
  def loaded_revision(source) do
    State.loaded_revision(state(source))
  end

  @spec runtime_state(term()) :: Ogol.Session.RuntimeState.t()
  def runtime_state(source) do
    State.runtime(state(source))
  end

  @spec runtime_realized?(term()) :: boolean()
  def runtime_realized?(source) do
    State.runtime_realized?(state(source))
  end

  @spec runtime_dirty?(term()) :: boolean()
  def runtime_dirty?(source) do
    State.runtime_dirty?(state(source))
  end

  @spec runtime_artifact_status(term(), State.kind(), String.t()) :: term() | nil
  def runtime_artifact_status(source, kind, id) when is_atom(kind) and is_binary(id) do
    State.runtime_artifact_status(state(source), kind, id)
  end

  @spec runtime_current(term(), State.kind(), String.t()) :: module() | nil
  def runtime_current(source, kind, id) when is_atom(kind) and is_binary(id) do
    State.runtime_current(state(source), kind, id)
  end

  @spec machine_contract_descriptor(term(), String.t()) :: term() | nil
  def machine_contract_descriptor(source, machine_id) when is_binary(machine_id) do
    State.machine_contract_descriptor(state(source), machine_id)
  end

  @spec list_entries(term(), State.kind()) :: [term()]
  def list_entries(source, kind) when is_atom(kind) do
    State.list_entries(state(source), kind)
  end

  @spec fetch(term(), State.kind(), String.t()) :: term() | nil
  def fetch(source, kind, id) when is_atom(kind) and is_binary(id) do
    State.fetch(state(source), kind, id)
  end

  @spec fetch_hardware_config(term(), String.t() | atom()) :: term() | nil
  def fetch_hardware_config(source, id) when is_binary(id) do
    fetch(source, :hardware_config, id)
  end

  def fetch_hardware_config(source, adapter) when is_atom(adapter) do
    fetch_hardware_config(source, Ogol.Hardware.Config.artifact_id(adapter))
  end

  @spec hardware_config_model(term(), String.t() | atom()) :: term()
  def hardware_config_model(source, id) when is_binary(id) do
    State.hardware_config_model(state(source), id)
  end

  def hardware_config_model(source, adapter) when is_atom(adapter) do
    hardware_config_model(source, Ogol.Hardware.Config.artifact_id(adapter))
  end

  @spec fetch_simulator_config(term(), String.t() | atom()) :: term() | nil
  def fetch_simulator_config(source, id) when is_binary(id) do
    fetch(source, :simulator_config, id)
  end

  def fetch_simulator_config(source, adapter) when is_atom(adapter) do
    fetch_simulator_config(source, Ogol.Hardware.Config.artifact_id(adapter))
  end

  @spec simulator_config_model(term(), String.t() | atom()) :: term()
  def simulator_config_model(source, id) when is_binary(id) do
    State.simulator_config_model(state(source), id)
  end

  def simulator_config_model(source, adapter) when is_atom(adapter) do
    simulator_config_model(source, Ogol.Hardware.Config.artifact_id(adapter))
  end

  defp put_client_id(socket, client_id) do
    put_in(socket.private[:session_client_id], client_id)
  end

  defp put_state(socket, %State{} = session_state) do
    socket = put_in(socket.private[:session_state], session_state)
    Component.assign(socket, :session_state, session_state)
  end
end
