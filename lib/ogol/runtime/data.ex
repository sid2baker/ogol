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
      signal_sink: nil,
      topology_router: nil,
      timeout_refs: %{},
      monitor_names: %{},
      monitor_refs: %{},
      link_targets: %{},
      link_pids: %{}
    }
  ]
end
