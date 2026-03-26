defmodule Ogol.Topology.Router do
  @moduledoc false

  use GenServer

  defstruct [
    :parent_machine_id,
    :parent_pid,
    child_specs: %{},
    child_pids: %{},
    child_monitors: %{},
    waiters: []
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def await_ready(router, timeout \\ 5_000) do
    GenServer.call(router, :await_ready, timeout)
  end

  def request_parent(router, name, data, meta, timeout) do
    GenServer.call(router, {:request_parent, name, data, meta, timeout}, timeout + 100)
  end

  def event_parent(router, name, data, meta) do
    GenServer.call(router, {:event_parent, name, data, meta})
  end

  def child_pid(router, child_name) do
    GenServer.call(router, {:child_pid, child_name})
  end

  def parent_pid(router) do
    GenServer.call(router, :parent_pid)
  end

  def send_event(router, target, name, data, meta) do
    GenServer.call(router, {:send_event, target, name, data, meta})
  end

  def send_request(router, target, name, data, meta, timeout) do
    GenServer.call(router, {:send_request, target, name, data, meta, timeout}, timeout + 100)
  end

  @impl true
  def init(opts) do
    children =
      opts
      |> Keyword.get(:children, [])
      |> Map.new(fn child ->
        {child.name,
         %{
           state_bindings: Map.new(child.state_bindings || []),
           signal_bindings: Map.new(child.signal_bindings || []),
           down_binding: child.down_binding
         }}
      end)

    {:ok,
     %__MODULE__{
       parent_machine_id: Keyword.fetch!(opts, :parent_machine_id),
       child_specs: children
     }}
  end

  @impl true
  def handle_call(:await_ready, from, state) do
    if ready?(state) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [from | state.waiters]}}
    end
  end

  def handle_call(:brain_pid, _from, state) do
    {:reply, state.parent_pid, state}
  end

  def handle_call(:parent_pid, _from, state) do
    {:reply, state.parent_pid, state}
  end

  def handle_call({:child_pid, child_name}, _from, state) do
    {:reply, Map.get(state.child_pids, child_name), state}
  end

  def handle_call({:request_parent, name, data, meta, timeout}, _from, state) do
    {:reply, do_request(state.parent_pid, name, data, meta, timeout), state}
  end

  def handle_call({:event_parent, name, data, meta}, _from, state) do
    {:reply, do_event(state.parent_pid, name, data, meta), state}
  end

  def handle_call({:send_event, target, name, data, meta}, _from, state) do
    {:reply, do_event(Map.get(state.child_pids, target), name, data, meta), state}
  end

  def handle_call({:send_request, target, name, data, meta, timeout}, _from, state) do
    {:reply, do_request(Map.get(state.child_pids, target), name, data, meta, timeout), state}
  end

  @impl true
  def handle_info({:ogol_machine_started, machine_id, pid}, state) do
    next_state =
      cond do
        machine_id == state.parent_machine_id ->
          %{state | parent_pid: pid}

        Map.has_key?(state.child_specs, machine_id) ->
          monitor_child(state, machine_id, pid)

        true ->
          state
      end

    {:noreply, maybe_reply_waiters(next_state)}
  end

  def handle_info({:ogol_state_entered, machine_id, state_name}, state) do
    case state.child_specs[machine_id] do
      %{state_bindings: bindings} ->
        child_pid = Map.get(state.child_pids, machine_id)

        maybe_route_to_parent(
          state.parent_pid,
          Map.get(bindings, state_name),
          %{},
          %{origin: :child, child: machine_id, child_pid: child_pid, state: state_name}
        )

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:ogol_signal, machine_id, signal_name, data, meta}, state) do
    case state.child_specs[machine_id] do
      %{signal_bindings: bindings} ->
        child_pid = Map.get(state.child_pids, machine_id)

        maybe_route_to_parent(
          state.parent_pid,
          Map.get(bindings, signal_name),
          data,
          meta
          |> Map.put(:origin, :child)
          |> Map.put(:child, machine_id)
          |> Map.put(:child_pid, child_pid)
        )

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.child_monitors, fn {_child_name, monitor_ref} -> monitor_ref == ref end) do
      {child_name, ^ref} ->
        next_state = demonitor_child(state, child_name)

        case next_state.child_specs[child_name] do
          %{down_binding: binding} when is_atom(binding) ->
            maybe_route_to_parent(
              next_state.parent_pid,
              binding,
              %{reason: reason},
              %{origin: :child, child: child_name, child_pid: pid}
            )

          _ ->
            :ok
        end

        {:noreply, next_state}

      nil ->
        {:noreply, state}
    end
  end

  defp ready?(state) do
    is_pid(state.parent_pid) and
      Enum.all?(Map.keys(state.child_specs), &Map.has_key?(state.child_pids, &1))
  end

  defp maybe_reply_waiters(state) do
    if ready?(state) do
      Enum.each(state.waiters, &GenServer.reply(&1, :ok))
      %{state | waiters: []}
    else
      state
    end
  end

  defp monitor_child(state, child_name, pid) do
    if old_ref = state.child_monitors[child_name] do
      Process.demonitor(old_ref, [:flush])
    end

    ref = Process.monitor(pid)

    %{
      state
      | child_pids: Map.put(state.child_pids, child_name, pid),
        child_monitors: Map.put(state.child_monitors, child_name, ref)
    }
  end

  defp demonitor_child(state, child_name) do
    %{
      state
      | child_pids: Map.delete(state.child_pids, child_name),
        child_monitors: Map.delete(state.child_monitors, child_name)
    }
  end

  defp maybe_route_to_parent(_parent_pid, nil, _data, _meta), do: :ok
  defp maybe_route_to_parent(nil, _name, _data, _meta), do: :ok

  defp maybe_route_to_parent(parent_pid, name, data, meta) do
    Ogol.event(parent_pid, name, data, meta)
  end

  defp do_event(nil, _name, _data, _meta), do: {:error, :target_unavailable}

  defp do_event(target, name, data, meta) do
    Ogol.event(target, name, data, meta)
  rescue
    _ -> {:error, :target_unavailable}
  catch
    :exit, reason -> {:error, {:target_exit, reason}}
  end

  defp do_request(nil, _name, _data, _meta, _timeout), do: {:error, :target_unavailable}

  defp do_request(target, name, data, meta, timeout) do
    case Ogol.request(target, name, data, meta, timeout) do
      {:error, reason} -> {:error, reason}
      _reply -> :ok
    end
  rescue
    _ -> {:error, :target_unavailable}
  catch
    :exit, reason -> {:error, {:target_exit, reason}}
  end
end
