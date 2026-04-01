defmodule Ogol.Runtime.TopologySnapshot do
  @moduledoc false

  @enforce_keys [:topology_id, :health]
  defstruct [
    :topology_id,
    :health,
    :connected?,
    meta: %{}
  ]
end
