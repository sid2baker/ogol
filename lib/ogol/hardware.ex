defmodule Ogol.Hardware do
  @moduledoc false

  alias Ogol.Hardware.EtherCAT.Ref, as: EtherCATRef

  @spec adapter_for(term()) :: module()
  def adapter_for(%EtherCATRef{}), do: Ogol.Hardware.EtherCAT.Adapter

  def adapter_for(refs) when is_list(refs) do
    if refs != [] and Enum.all?(refs, &match?(%EtherCATRef{}, &1)) do
      Ogol.Hardware.EtherCAT.Adapter
    else
      Ogol.Hardware.NoopAdapter
    end
  end

  def adapter_for(_hardware_ref), do: Ogol.Hardware.NoopAdapter
end
