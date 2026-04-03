defmodule Ogol.TestSupport.EthercatRuntimeHelper do
  @moduledoc false

  alias Ogol.Hardware.EtherCAT.RuntimeHost

  @spec ensure_started!() :: :ok
  def ensure_started! do
    case Process.whereis(EtherCAT.Master) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        ensure_runtime_started!()
    end
  end

  defp ensure_runtime_started! do
    case RuntimeHost.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> raise "failed to start EtherCAT.Runtime: #{inspect(reason)}"
    end
  end
end
