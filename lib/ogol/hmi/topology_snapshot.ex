defmodule Ogol.HMI.TopologySnapshot do
  @moduledoc false

  @enforce_keys [:topology_id, :root_machine_id, :health]
  defstruct [
    :topology_id,
    :root_machine_id,
    :health,
    :connected?,
    dependencies: [],
    restart_summary: %{},
    connectivity: %{},
    meta: %{}
  ]
end
