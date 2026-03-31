defmodule Ogol.Runtime.Data do
  @moduledoc false

  defstruct [
    :machine_id,
    :hardware_adapter,
    :hardware_ref,
    facts: %{},
    fields: %{},
    outputs: %{},
    meta: %{
      machine_module: nil,
      signal_sink: nil,
      timeout_refs: %{}
    }
  ]
end
