defmodule Ogol.Machine.ForeignAction do
  @moduledoc """
  Explicit foreign action escape hatch for generated Ogol machine runtimes.

  Foreign actions are typed extension points. They are not part of the normal
  declarative action vocabulary, but they stay explicit and structured.
  """

  @callback run(
              kind :: atom(),
              opts :: keyword(),
              machine_module :: module(),
              delivered :: Ogol.Runtime.DeliveredEvent.t() | nil,
              staging :: Ogol.Runtime.Staging.t()
            ) :: {:ok, Ogol.Runtime.Staging.t()} | {:error, term()}
end
