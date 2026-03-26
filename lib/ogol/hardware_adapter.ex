defmodule Ogol.HardwareAdapter do
  @moduledoc """
  Behaviour for outbound hardware interaction from generated machine brains.
  """

  @callback dispatch(
              machine :: module(),
              hardware_ref :: term(),
              command :: atom(),
              data :: map(),
              meta :: map()
            ) ::
              :ok | {:error, term()}

  @callback write_output(
              machine :: module(),
              hardware_ref :: term(),
              output :: atom(),
              value :: term(),
              meta :: map()
            ) ::
              :ok | {:error, term()}

  @callback attach(
              machine :: module(),
              server :: pid(),
              hardware_ref :: term()
            ) ::
              :ok | {:error, term()}

  @optional_callbacks write_output: 5, attach: 3
end
