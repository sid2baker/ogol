defmodule Ogol.Sequence.Dsl do
  @moduledoc false

  defmodule Proc do
    defstruct [
      :name,
      :meaning,
      :__identifier__,
      body: [],
      __spark_metadata__: nil
    ]
  end

  defmodule Invariant do
    defstruct [:condition, :meaning, :__spark_metadata__]
  end

  defmodule DoSkill do
    defstruct [
      :machine,
      :skill,
      :when,
      :timeout,
      :meaning,
      :__spark_metadata__
    ]
  end

  defmodule Wait do
    defstruct [
      :condition,
      :timeout,
      :fail,
      :signal?,
      :when,
      :meaning,
      :__spark_metadata__
    ]
  end

  defmodule Run do
    defstruct [:procedure, :when, :meaning, :__spark_metadata__]
  end

  defmodule Delay do
    defstruct [:duration_ms, :meaning, :__spark_metadata__]
  end

  defmodule Repeat do
    defstruct [:when, :meaning, body: [], __spark_metadata__: nil]
  end

  defmodule Fail do
    defstruct [:message, :meaning, :__spark_metadata__]
  end

  @sequence_steps []

  @do_skill %Spark.Dsl.Entity{
    name: :do_skill,
    target: DoSkill,
    args: [:machine, :skill],
    schema: [
      machine: [type: :atom, required: true],
      skill: [type: :atom, required: true],
      when: [type: :any],
      timeout: [type: :non_neg_integer],
      meaning: [type: :string]
    ]
  }

  @wait %Spark.Dsl.Entity{
    name: :wait,
    target: Wait,
    args: [:condition],
    schema: [
      condition: [type: :any, required: true],
      timeout: [type: :non_neg_integer],
      fail: [type: :string],
      signal?: [type: :boolean, default: false],
      when: [type: :any],
      meaning: [type: :string]
    ]
  }

  @run %Spark.Dsl.Entity{
    name: :run,
    target: Run,
    args: [:procedure],
    schema: [
      procedure: [type: :atom, required: true],
      when: [type: :any],
      meaning: [type: :string]
    ]
  }

  @delay %Spark.Dsl.Entity{
    name: :delay,
    target: Delay,
    args: [:duration_ms],
    schema: [
      duration_ms: [type: :non_neg_integer, required: true],
      meaning: [type: :string]
    ]
  }

  @fail %Spark.Dsl.Entity{
    name: :fail,
    target: Fail,
    args: [:message],
    schema: [
      message: [type: :string, required: true],
      meaning: [type: :string]
    ]
  }

  @repeat %Spark.Dsl.Entity{
    name: :repeat,
    target: Repeat,
    auto_set_fields: [body: []],
    entities: [
      body: [@do_skill, @wait, @run, @delay, @fail]
    ],
    schema: [
      when: [type: :any],
      meaning: [type: :string]
    ]
  }

  @sequence_steps [@do_skill, @wait, @run, @delay, @repeat, @fail]

  @proc %Spark.Dsl.Entity{
    name: :proc,
    target: Proc,
    args: [:name],
    identifier: :name,
    auto_set_fields: [body: []],
    entities: [
      body: @sequence_steps
    ],
    schema: [
      name: [type: :atom, required: true],
      meaning: [type: :string]
    ]
  }

  @invariant %Spark.Dsl.Entity{
    name: :invariant,
    target: Invariant,
    args: [:condition],
    schema: [
      condition: [type: :any, required: true],
      meaning: [type: :string]
    ]
  }

  @sequence %Spark.Dsl.Section{
    name: :sequence,
    schema: [
      name: [type: :atom, required: true, doc: "Sequence name."],
      topology: [type: :atom, required: true, doc: "Topology module providing machine contracts."],
      meaning: [type: :string, doc: "Human-readable sequence meaning."]
    ],
    entities: [@invariant, @proc | @sequence_steps]
  }

  use Spark.Dsl.Extension,
    sections: [@sequence],
    verifiers: [Ogol.Sequence.Verifiers.ValidateSpec]
end
