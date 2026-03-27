defmodule Ogol.Topology.Model do
  @moduledoc false

  defstruct [
    :module,
    :root,
    :strategy,
    :meaning,
    machines: [],
    observations: []
  ]
end
