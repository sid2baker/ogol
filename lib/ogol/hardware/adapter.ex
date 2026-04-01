defmodule Ogol.Hardware.Adapter do
  @moduledoc """
  Behaviour for outbound hardware interaction from generated machine brains.
  """

  @callback dispatch(
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

  @callback attach(
              machine :: module(),
              server :: pid(),
              binding :: term()
            ) ::
              :ok | {:error, term()}

  @optional_callbacks write_output: 5, attach: 3
end
