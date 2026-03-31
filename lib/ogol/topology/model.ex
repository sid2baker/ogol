defmodule Ogol.Topology.Model do
  @moduledoc false

  defstruct [
    :module,
    :topology_id,
    :strategy,
    :meaning,
    machines: []
  ]
end
