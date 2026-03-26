defmodule Ogol.HMI.TopologySnapshot do
  @moduledoc false

  @enforce_keys [:topology_id, :parent_machine_id, :health]
  defstruct [
    :topology_id,
    :parent_machine_id,
    :health,
    :connected?,
    children: [],
    restart_summary: %{},
    connectivity: %{},
    meta: %{}
  ]
end
