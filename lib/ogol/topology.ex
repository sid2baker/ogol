defmodule Ogol.Topology do
  @moduledoc """
  Spark-backed authoring entrypoint for explicit Ogol topologies.

  Topology modules own deployment, supervision, and machine instance naming.
  Cross-machine orchestration lives in sequences, not in machine topology wiring.
  """

  use Spark.Dsl,
    default_extensions: [
      extensions: [Ogol.Topology.Dsl]
    ]

  def handle_before_compile(_opts) do
    quote generated: true do
      require Ogol.Topology.Generate
      Ogol.Topology.Generate.inject()
    end
  end
end
