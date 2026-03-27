defmodule Ogol.Topology.Dsl do
  @moduledoc false

  defmodule TopologyOptions do
    defstruct [:root, :strategy, :meaning, :__spark_metadata__]
  end

  defmodule Machine do
    defstruct [:name, :module, :opts, :restart, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule ObserveState do
    defstruct [:source, :state, :as, :meaning, :__spark_metadata__]
  end

  defmodule ObserveSignal do
    defstruct [:source, :signal, :as, :meaning, :__spark_metadata__]
  end

  defmodule ObserveStatus do
    defstruct [:source, :item, :as, :meaning, :__spark_metadata__]
  end

  defmodule ObserveDown do
    defstruct [:source, :as, :meaning, :__spark_metadata__]
  end

  @topology %Spark.Dsl.Section{
    name: :topology,
    schema: [
      root: [type: :atom, required: true, doc: "Root/coordinator machine name."],
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

  @observe_state %Spark.Dsl.Entity{
    name: :observe_state,
    target: ObserveState,
    args: [:source, :state],
    schema: [
      source: [type: :atom, required: true],
      state: [type: :atom, required: true],
      as: [type: :atom, required: true],
      meaning: [type: :string]
    ]
  }

  @observe_signal %Spark.Dsl.Entity{
    name: :observe_signal,
    target: ObserveSignal,
    args: [:source, :signal],
    schema: [
      source: [type: :atom, required: true],
      signal: [type: :atom, required: true],
      as: [type: :atom, required: true],
      meaning: [type: :string]
    ]
  }

  @observe_down %Spark.Dsl.Entity{
    name: :observe_down,
    target: ObserveDown,
    args: [:source],
    schema: [
      source: [type: :atom, required: true],
      as: [type: :atom, required: true],
      meaning: [type: :string]
    ]
  }

  @observe_status %Spark.Dsl.Entity{
    name: :observe_status,
    target: ObserveStatus,
    args: [:source, :item],
    schema: [
      source: [type: :atom, required: true],
      item: [type: :atom, required: true],
      as: [type: :atom, required: true],
      meaning: [type: :string]
    ]
  }

  @observations %Spark.Dsl.Section{
    name: :observations,
    entities: [@observe_state, @observe_signal, @observe_status, @observe_down]
  }

  use Spark.Dsl.Extension,
    sections: [
      @topology,
      @machines,
      @observations
    ],
    verifiers: [Ogol.Topology.Verifiers.ValidateSpec]
end
