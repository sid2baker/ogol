defmodule Ogol.Topology.Router do
  @moduledoc false

  use GenServer

  defstruct [
    :root_machine_id,
    :root_pid,
    observation_specs: %{},
    observed_pids: %{},
    observed_monitors: %{},
    observed_status: %{},
    waiters: []
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def await_ready(router, timeout \\ 5_000) do
    GenServer.call(router, :await_ready, timeout)
  end

  def root_pid(router) do
    GenServer.call(router, :root_pid)
  end

  def invoke(router, target, skill, args, meta, timeout \\ 5_000) do
    GenServer.call(router, {:invoke, target, skill, args, meta, timeout}, timeout + 100)
  end

  @impl true
  def init(opts) do
    observations =
      opts
      |> Keyword.get(:observations, [])
      |> Map.new(fn observation ->
        {Map.fetch!(observation, :name),
         %{
           state_bindings: Map.new(Map.get(observation, :state_bindings, []) || []),
           signal_bindings: Map.new(Map.get(observation, :signal_bindings, []) || []),
           status_bindings: Map.new(Map.get(observation, :status_bindings, []) || []),
           down_binding: Map.get(observation, :down_binding)
         }}
      end)

    {:ok,
     %__MODULE__{
       root_machine_id: Keyword.fetch!(opts, :root_machine_id),
       observation_specs: observations
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
    {:reply, state.root_pid, state}
  end

  def handle_call(:root_pid, _from, state) do
    {:reply, state.root_pid, state}
  end

  def handle_call({:invoke, target, skill, args, meta, timeout}, _from, state) do
    target_pid = Ogol.Topology.Registry.whereis(target) || Map.get(state.observed_pids, target)
    {:reply, do_invoke(target_pid, skill, args, meta, timeout), state}
  end

  @impl true
  def handle_info({:ogol_machine_started, machine_id, pid}, state) do
    next_state =
      cond do
        machine_id == state.root_machine_id ->
          %{state | root_pid: pid}

        Map.has_key?(state.observation_specs, machine_id) ->
          monitor_observed_machine(state, machine_id, pid)

        true ->
          state
      end

    {:noreply, maybe_reply_waiters(next_state)}
  end

  def handle_info({:ogol_state_entered, machine_id, state_name}, state) do
    case state.observation_specs[machine_id] do
      %{state_bindings: bindings} ->
        dependency_pid = Map.get(state.observed_pids, machine_id)

        Ogol.HMI.RuntimeNotifier.emit(:dependency_state_entered,
          machine_id: state.root_machine_id,
          topology_id: state.root_machine_id,
          source: __MODULE__,
          payload: %{dependency: machine_id, state: state_name},
          meta: %{dependency_pid: dependency_pid}
        )

        maybe_route_to_root(
          state.root_pid,
          Map.get(bindings, state_name),
          %{},
          %{
            origin: :dependency,
            dependency: machine_id,
            dependency_pid: dependency_pid,
            state: state_name
          }
        )

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:ogol_signal, machine_id, signal_name, data, meta}, state) do
    case state.observation_specs[machine_id] do
      %{signal_bindings: bindings} ->
        dependency_pid = Map.get(state.observed_pids, machine_id)

        Ogol.HMI.RuntimeNotifier.emit(:dependency_signal_emitted,
          machine_id: state.root_machine_id,
          topology_id: state.root_machine_id,
          source: __MODULE__,
          payload: %{dependency: machine_id, signal: signal_name, data: data},
          meta: Map.put(meta, :dependency_pid, dependency_pid)
        )

        maybe_route_to_root(
          state.root_pid,
          Map.get(bindings, signal_name),
          data,
          meta
          |> Map.put(:origin, :dependency)
          |> Map.put(:dependency, machine_id)
          |> Map.put(:dependency_pid, dependency_pid)
        )

      _ ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info({:ogol_public_status, machine_id, public_status}, state) do
    case state.observation_specs[machine_id] do
      %{status_bindings: bindings} when map_size(bindings) > 0 ->
        dependency_pid = Map.get(state.observed_pids, machine_id)
        previous = Map.get(state.observed_status, machine_id, %{})

        next_state = %{
          state
          | observed_status: Map.put(state.observed_status, machine_id, public_status || %{})
        }

        Enum.each(bindings, fn {item, binding} ->
          current_value = Map.get(public_status || %{}, item)
          previous_value = Map.get(previous, item, :__ogol_missing__)

          if previous_value != current_value do
            Ogol.HMI.RuntimeNotifier.emit(:dependency_status_updated,
              machine_id: state.root_machine_id,
              topology_id: state.root_machine_id,
              source: __MODULE__,
              payload: %{dependency: machine_id, item: item, value: current_value},
              meta: %{dependency_pid: dependency_pid}
            )

            maybe_route_to_root(
              next_state.root_pid,
              binding,
              %{value: current_value},
              %{
                origin: :dependency,
                dependency: machine_id,
                dependency_pid: dependency_pid,
                status: item
              }
            )
          end
        end)

        {:noreply, next_state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Enum.find(state.observed_monitors, fn {_machine_name, monitor_ref} ->
           monitor_ref == ref
         end) do
      {machine_name, ^ref} ->
        next_state = demonitor_observed_machine(state, machine_name)

        Ogol.HMI.RuntimeNotifier.emit(:dependency_down,
          machine_id: state.root_machine_id,
          topology_id: state.root_machine_id,
          source: __MODULE__,
          payload: %{dependency: machine_name, reason: reason},
          meta: %{dependency_pid: pid}
        )

        case next_state.observation_specs[machine_name] do
          %{down_binding: binding} when is_atom(binding) ->
            maybe_route_to_root(
              next_state.root_pid,
              binding,
              %{reason: reason},
              %{origin: :dependency, dependency: machine_name, dependency_pid: pid}
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
    is_pid(state.root_pid) and
      Enum.all?(Map.keys(state.observation_specs), &Map.has_key?(state.observed_pids, &1))
  end

  defp maybe_reply_waiters(state) do
    if ready?(state) do
      Enum.each(state.waiters, &GenServer.reply(&1, :ok))
      %{state | waiters: []}
    else
      state
    end
  end

  defp monitor_observed_machine(state, machine_name, pid) do
    if old_ref = state.observed_monitors[machine_name] do
      Process.demonitor(old_ref, [:flush])
    end

    ref = Process.monitor(pid)

    %{
      state
      | observed_pids: Map.put(state.observed_pids, machine_name, pid),
        observed_monitors: Map.put(state.observed_monitors, machine_name, ref)
    }
  end

  defp demonitor_observed_machine(state, machine_name) do
    %{
      state
      | observed_pids: Map.delete(state.observed_pids, machine_name),
        observed_monitors: Map.delete(state.observed_monitors, machine_name),
        observed_status: Map.delete(state.observed_status, machine_name)
    }
  end

  defp maybe_route_to_root(nil, _name, _data, _meta), do: :ok

  defp maybe_route_to_root(root_pid, name, data, meta) do
    Ogol.Runtime.Delivery.event(root_pid, name, data, meta)
  end

  defp do_invoke(nil, _skill, _args, _meta, _timeout), do: {:error, :target_unavailable}

  defp do_invoke(target, skill, args, meta, timeout) do
    case Ogol.invoke(target, skill, args, meta: meta, timeout: timeout) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _ -> {:error, :target_unavailable}
  catch
    :exit, reason -> {:error, {:target_exit, reason}}
  end
end
