defmodule Ogol.Hardware.EtherCAT.RuntimeHost do
  @moduledoc false

  alias EtherCAT.Runtime, as: EtherCATRuntime

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts \\ []) do
    if Code.ensure_loaded?(EtherCATRuntime) and
         function_exported?(EtherCATRuntime, :start_link, 0) do
      apply(EtherCATRuntime, :start_link, [])
    else
      {:error, :ethercat_runtime_not_available}
    end
  end
end
