defmodule Ogol.Hardware.EtherCAT do
  @moduledoc """
  Thin EtherCAT helpers over the external `:ethercat` dependency.

  Ogol does not implement EtherCAT itself. This module only normalizes public
  `EtherCAT.Event` messages into Ogol hardware deliveries.
  """

  alias EtherCAT.Event
  alias Ogol.Hardware.EtherCAT.Ref
  alias Ogol.Runtime.DeliveredEvent

  @spec normalize_message(term(), term()) :: DeliveredEvent.t() | nil
  def normalize_message(refs, message) when is_list(refs) do
    Enum.find_value(refs, &normalize_message(&1, message))
  end

  def normalize_message(
        %Ref{} = ref,
        %Event{
          kind: :signal_changed,
          slave: slave,
          signal: {_slave, endpoint},
          value: value,
          cycle: cycle,
          updated_at_us: updated_at_us
        }
      ) do
    if slave == ref.slave and Ref.observes_fact?(ref, endpoint) do
      delivered_from_signal(ref, endpoint, value, %{
        slave: slave,
        endpoint: endpoint,
        cycle: cycle,
        updated_at_us: updated_at_us,
        source: :runtime
      })
    end
  end

  def normalize_message(
        %Ref{} = ref,
        %Event{
          slave: slave,
          kind: kind,
          data: data,
          cycle: cycle,
          updated_at_us: updated_at_us
        }
      ) do
    if slave == ref.slave and Ref.observes_events?(ref) do
      %DeliveredEvent{
        family: :hardware,
        name: Ref.event_name(ref),
        data: %{event: data},
        meta:
          ref.meta
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

  def normalize_message(_hardware_ref, _message), do: nil

  defp delivered_from_signal(%Ref{} = ref, endpoint, value, meta) do
    %DeliveredEvent{
      family: :hardware,
      name: :process_image,
      data: %{value: value, facts: %{endpoint => value}},
      meta: ref.meta |> Map.merge(meta) |> Map.put(:bus, :ethercat)
    }
  end
end
