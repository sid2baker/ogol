defmodule Ogol.Runtime.Normalize do
  @moduledoc false

  alias Ogol.Runtime.DeliveredEvent

  @spec delivered(term(), term(), Ogol.Runtime.Data.t()) ::
          DeliveredEvent.t() | {:stop, term()} | nil
  def delivered({:call, from}, {:request, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :request, name: name, data: data, meta: meta, from: from}
  end

  def delivered(:cast, {:event, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :event, name: name, data: data, meta: meta}
  end

  def delivered(:info, {:ogol_hardware_event, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :hardware, name: name, data: data, meta: meta}
  end

  def delivered(
        :info,
        {:ethercat_simulator, _simulator, :signal_changed, _slave, _signal, _value} = message,
        machine_data
      ) do
    Ogol.Hardware.EtherCAT.normalize_message(machine_data.hardware_ref, message)
  end

  def delivered(:info, %EtherCAT.Event{} = message, machine_data) do
    Ogol.Hardware.EtherCAT.normalize_message(machine_data.hardware_ref, message)
  end

  def delivered(:info, {:ogol_state_timeout, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :state_timeout, name: name, data: data, meta: meta}
  end

  def delivered(:internal, {:ogol_internal, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :internal, name: name, data: data, meta: meta}
  end

  def delivered(:info, {:DOWN, ref, :process, pid, reason}, machine_data) do
    case get_in(machine_data.meta, [:monitor_refs, ref]) do
      %{name: name, target: target} ->
        %DeliveredEvent{
          family: :monitor,
          name: name,
          data: %{reason: reason},
          meta: %{target: target, pid: pid, ref: ref}
        }

      _ ->
        nil
    end
  end

  def delivered(:info, {:EXIT, pid, reason}, machine_data) do
    case get_in(machine_data.meta, [:link_pids, pid]) do
      nil ->
        if reason == :normal, do: nil, else: {:stop, reason}

      target ->
        %DeliveredEvent{
          family: :link,
          name: :exit,
          data: %{reason: reason},
          meta: %{target: target, pid: pid}
        }
    end
  end

  def delivered(_type, _content, _machine_data), do: nil

  @spec maybe_merge_fact_patch(Ogol.Runtime.Data.t(), DeliveredEvent.t()) :: Ogol.Runtime.Data.t()
  def maybe_merge_fact_patch(data, %DeliveredEvent{family: family, data: event_data})
      when family in [:event, :hardware] do
    fact_patch = Map.get(event_data, :facts) || Map.get(event_data, "facts")

    if is_map(fact_patch) do
      %{data | facts: Map.merge(data.facts, fact_patch)}
    else
      data
    end
  end

  def maybe_merge_fact_patch(data, %DeliveredEvent{
        family: :monitor,
        name: name,
        meta: %{ref: ref}
      }) do
    monitor_names = Map.get(data.meta, :monitor_names, %{})
    monitor_refs = Map.get(data.meta, :monitor_refs, %{})

    %{
      data
      | meta:
          data.meta
          |> Map.put(:monitor_names, Map.delete(monitor_names, name))
          |> Map.put(:monitor_refs, Map.delete(monitor_refs, ref))
    }
  end

  def maybe_merge_fact_patch(data, %DeliveredEvent{
        family: :link,
        meta: %{target: target, pid: pid}
      }) do
    link_targets = Map.get(data.meta, :link_targets, %{})
    link_pids = Map.get(data.meta, :link_pids, %{})

    %{
      data
      | meta:
          data.meta
          |> Map.put(:link_targets, Map.delete(link_targets, target))
          |> Map.put(:link_pids, Map.delete(link_pids, pid))
    }
  end

  def maybe_merge_fact_patch(data, _delivered), do: data
end
