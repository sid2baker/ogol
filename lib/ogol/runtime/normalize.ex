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

  def delivered(:info, %EtherCAT.Event{} = message, machine_data) do
    Ogol.Hardware.EtherCAT.normalize_message(machine_data.io_binding, message)
  end

  def delivered(:info, {:ogol_state_timeout, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :state_timeout, name: name, data: data, meta: meta}
  end

  def delivered(:internal, {:ogol_internal, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :internal, name: name, data: data, meta: meta}
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

  def maybe_merge_fact_patch(data, _delivered), do: data
end
