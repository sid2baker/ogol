defmodule Ogol.Hardware do
  @moduledoc false

  alias Ogol.Hardware.EtherCAT
  alias Ogol.Runtime.DeliveredEvent
  alias Ogol.Topology.Wiring

  @type adapter_t :: :ethercat
  @type t :: EtherCAT.t()

  @callback hardware() :: t()
  @callback id() :: String.t()
  @callback label() :: String.t()
  @callback child_specs(keyword()) :: {:ok, [Supervisor.child_spec()]} | {:error, term()}
  @callback bind(Wiring.t()) :: {:ok, term() | nil} | {:error, term()}
  @callback normalize_message(term(), term()) :: DeliveredEvent.t() | nil
  @callback attach(machine :: module(), server :: pid(), binding :: term()) ::
              :ok | {:error, term()}
  @callback dispatch_command(
              machine :: module(),
              binding :: term(),
              command :: atom(),
              data :: map(),
              meta :: map()
            ) ::
              :ok | {:error, term()}
  @callback write_output(
              machine :: module(),
              binding :: term(),
              output :: atom(),
              value :: term(),
              meta :: map()
            ) ::
              :ok | {:error, term()}

  @optional_callbacks normalize_message: 2, attach: 3, write_output: 5

  defmacro __using__(_opts) do
    quote do
      use GenServer
      @behaviour Ogol.Hardware
    end
  end

  @spec artifact_id(adapter_t() | t()) :: String.t()
  def artifact_id(:ethercat), do: EtherCAT.artifact_id()
  def artifact_id(%EtherCAT{}), do: EtherCAT.artifact_id()

  @spec adapter(t()) :: adapter_t()
  def adapter(%EtherCAT{}), do: :ethercat

  @spec adapter_from_artifact_id(String.t()) :: {:ok, adapter_t()} | :error
  def adapter_from_artifact_id("ethercat"), do: {:ok, :ethercat}
  def adapter_from_artifact_id(_other), do: :error

  @spec label(adapter_t() | t()) :: String.t()
  def label(:ethercat), do: EtherCAT.default_label()
  def label(%EtherCAT{} = hardware), do: EtherCAT.label(hardware)
end
