defmodule Ogol.Hardware.Config do
  @moduledoc false

  alias Ogol.Hardware.Config.EtherCAT

  @type adapter_t :: :ethercat
  @type t :: EtherCAT.t()

  @spec adapter(t()) :: adapter_t()
  def adapter(%EtherCAT{}), do: :ethercat

  @spec artifact_id(adapter_t() | t()) :: String.t()
  def artifact_id(:ethercat), do: EtherCAT.artifact_id()
  def artifact_id(%EtherCAT{}), do: EtherCAT.artifact_id()

  @spec adapter_from_artifact_id(String.t()) :: {:ok, adapter_t()} | :error
  def adapter_from_artifact_id("ethercat"), do: {:ok, :ethercat}
  def adapter_from_artifact_id(_other), do: :error

  @spec label(adapter_t() | t()) :: String.t()
  def label(:ethercat), do: EtherCAT.default_label()
  def label(%EtherCAT{label: label}) when is_binary(label) and label != "", do: label
  def label(%EtherCAT{}), do: EtherCAT.default_label()

  @spec module_for_adapter(adapter_t()) :: module()
  def module_for_adapter(:ethercat), do: EtherCAT
end
