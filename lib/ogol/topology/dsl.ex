defmodule Ogol.Topology.Dsl do
  @moduledoc false

  defmodule TopologyOptions do
    defstruct [:strategy, :meaning, :__spark_metadata__]
  end

  defmodule Machine do
    defstruct [:name, :module, :opts, :restart, :meaning, :__identifier__, :__spark_metadata__]
  end

  @topology %Spark.Dsl.Section{
    name: :topology,
    schema: [
      strategy: [type: :atom, default: :one_for_one, doc: "Supervisor strategy."],
      meaning: [type: :string, doc: "Human-readable topology meaning."]
    ]
  }

  @machine %Spark.Dsl.Entity{
    name: :machine,
    target: Machine,
    args: [:name, :module],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      module: [type: :atom, required: true],
      opts: [type: :keyword_list, default: []],
      restart: [type: :atom, default: :permanent],
      meaning: [type: :string]
    ]
  }

  @machines %Spark.Dsl.Section{name: :machines, entities: [@machine]}

  use Spark.Dsl.Extension,
    sections: [@topology, @machines],
    verifiers: [Ogol.Topology.Verifiers.ValidateSpec]
end
