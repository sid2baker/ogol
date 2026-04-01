defmodule Ogol.Runtime.Data do
  @moduledoc false

  defstruct [
    :machine_id,
    :io_adapter,
    :io_binding,
    facts: %{},
    fields: %{},
    outputs: %{},
    meta: %{
      machine_module: nil,
      topology_id: nil,
      signal_sink: nil,
      timeout_refs: %{}
    }
  ]
end
