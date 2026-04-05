defmodule OgolWeb.HMI.OpsControl do
  @moduledoc false

  alias Ogol.Session

  @spec status() :: map()
  def status, do: Session.operator_orchestration_status()

  @spec dispatch(String.t()) :: {:ok, String.t(), atom()} | {:error, String.t(), term()}
  def dispatch("arm_auto") do
    case Session.set_control_mode(:auto) do
      :ok -> {:ok, "cell", :armed}
      other -> {:error, "cell", other}
    end
  end

  def dispatch("switch_to_manual") do
    case Session.set_control_mode(:manual) do
      :ok -> {:ok, "cell", :manual}
      other -> {:error, "cell", other}
    end
  end

  def dispatch("request_manual_takeover") do
    case Session.request_manual_takeover() do
      :ok -> {:ok, "cell", :takeover_requested}
      other -> {:error, "cell", other}
    end
  end

  def dispatch(action), do: {:error, "cell", {:unsupported_action, action}}

  @spec feedback(:ok | :error, String.t(), String.t(), term()) :: map()
  def feedback(status, target, action, detail) do
    %{status: status, target: target, action: action, detail: detail}
  end
end
