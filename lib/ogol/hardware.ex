defmodule Ogol.Hardware do
  @moduledoc false

  alias Ogol.Hardware.EtherCAT.Ref, as: EtherCATRef

  @spec normalize_ref(module(), term()) :: term()
  def normalize_ref(Ogol.Hardware.EtherCAT.Adapter, hardware_ref) do
    case EtherCATRef.normalize_runtime(hardware_ref) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> hardware_ref
    end
  end

  def normalize_ref(_adapter, hardware_ref), do: hardware_ref

  @spec adapter_for(term()) :: module()
  def adapter_for(hardware_ref) do
    case EtherCATRef.normalize_runtime(hardware_ref) do
      {:ok, []} -> Ogol.Hardware.NoopAdapter
      {:ok, _normalized} -> Ogol.Hardware.EtherCAT.Adapter
      {:error, _reason} -> Ogol.Hardware.NoopAdapter
    end
  end
end
