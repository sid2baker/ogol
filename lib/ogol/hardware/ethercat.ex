defmodule Ogol.Hardware.EtherCAT do
  @moduledoc """
  Thin EtherCAT helpers over the external `:ethercat` dependency.

  Ogol does not implement EtherCAT itself. This module only normalizes public
  `EtherCAT.Event` messages into Ogol hardware deliveries.
  """

  alias EtherCAT.Event
  alias Ogol.Hardware.EtherCAT.Binding
  alias Ogol.Runtime.DeliveredEvent

  @spec normalize_message(term(), term()) :: DeliveredEvent.t() | nil
  def normalize_message(refs, message) when is_list(refs) do
    Enum.find_value(refs, &normalize_message(&1, message))
  end

  def normalize_message(
        %Binding{} = binding,
        %Event{
          kind: :signal_changed,
          slave: slave,
          signal: {_slave, endpoint},
          value: value,
          cycle: cycle,
          updated_at_us: updated_at_us
        }
      ) do
    if slave == binding.slave and Binding.observes_fact?(binding, endpoint) do
      delivered_from_signal(binding, endpoint, value, %{
        slave: slave,
        endpoint: endpoint,
        cycle: cycle,
        updated_at_us: updated_at_us,
        source: :runtime
      })
    end
  end

  def normalize_message(
        %Binding{} = binding,
        %Event{
          slave: slave,
          kind: kind,
          data: data,
          cycle: cycle,
          updated_at_us: updated_at_us
        }
      ) do
    if slave == binding.slave and Binding.observes_events?(binding) do
      %DeliveredEvent{
        family: :hardware,
        name: Binding.event_name(binding),
        data: %{event: data},
        meta:
          binding.meta
          |> Map.merge(%{
            bus: :ethercat,
            slave: slave,
            kind: kind,
            cycle: cycle,
            updated_at_us: updated_at_us,
            source: :runtime
          })
      }
    end
  end

  def normalize_message(_binding, _message), do: nil

  defp delivered_from_signal(%Binding{} = binding, endpoint, value, meta) do
    fact_name = Binding.machine_fact_for_endpoint(binding, endpoint) || endpoint

    %DeliveredEvent{
      family: :hardware,
      name: :process_image,
      data: %{value: value, facts: %{fact_name => value}},
      meta: binding.meta |> Map.merge(meta) |> Map.put(:bus, :ethercat)
    }
  end
end
