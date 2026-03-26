defmodule Ogol.Hardware.EtherCAT do
  @moduledoc """
  Thin EtherCAT helpers over the external `:ethercat` dependency.

  Ogol does not implement EtherCAT itself. This module only:

  - forwards explicit hardware events into a generated machine brain
  - normalizes `EtherCAT` and `EtherCAT.Simulator` feedback back into Ogol
    hardware deliveries
  """

  alias EtherCAT.Event
  alias Ogol.Hardware.EtherCAT.Ref
  alias Ogol.Runtime.DeliveredEvent

  @spec event(GenServer.server(), atom(), map(), map()) :: :ok
  def event(server, name, data \\ %{}, meta \\ %{})
      when is_atom(name) and is_map(data) and is_map(meta) do
    Ogol.hardware_event(server, name, data, Map.put_new(meta, :bus, :ethercat))
  end

  @spec process_image(GenServer.server(), map(), map()) :: :ok
  def process_image(server, facts_patch, meta \\ %{}) when is_map(facts_patch) and is_map(meta) do
    event(server, :process_image, %{facts: facts_patch}, meta)
  end

  @spec normalize_message(term(), term()) :: DeliveredEvent.t() | nil
  def normalize_message(refs, message) when is_list(refs) do
    Enum.find_value(refs, &normalize_message(&1, message))
  end

  def normalize_message(
        %Ref{} = ref,
        {:ethercat_simulator, simulator, :signal_changed, slave, signal, value}
      ) do
    if slave == ref.slave and Ref.observes_signal?(ref, signal) do
      delivered_from_signal(ref, signal, value, %{
        slave: slave,
        signal: signal,
        simulator: simulator,
        source: :simulator
      })
    end
  end

  def normalize_message(
        %Ref{} = ref,
        %Event{
          kind: :signal_changed,
          slave: slave,
          signal: {_slave, signal},
          value: value,
          cycle: cycle,
          updated_at_us: updated_at_us
        }
      ) do
    if slave == ref.slave and Ref.observes_signal?(ref, signal) do
      delivered_from_signal(ref, signal, value, %{
        slave: slave,
        signal: signal,
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
        name: ref.hardware_event,
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

  defp delivered_from_signal(%Ref{} = ref, signal, value, meta) do
    fact_patch =
      case Map.fetch(ref.fact_map, signal) do
        {:ok, fact_name} -> %{fact_name => value}
        :error -> %{}
      end

    data =
      if map_size(fact_patch) == 0 do
        %{value: value}
      else
        %{value: value, facts: fact_patch}
      end

    %DeliveredEvent{
      family: :hardware,
      name: ref.hardware_event,
      data: data,
      meta: ref.meta |> Map.merge(meta) |> Map.put(:bus, :ethercat)
    }
  end
end
