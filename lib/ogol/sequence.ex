defmodule Ogol.Sequence do
  @moduledoc """
  Spark-backed authoring entrypoint for Ogol sequence modules.

  Sequence modules compile into validated canonical sequence models that Ogol
  executes directly through the sequence runner runtime.
  """

  use Spark.Dsl,
    default_extensions: [
      extensions: [Ogol.Sequence.Dsl]
    ]

  def handle_before_compile(_opts) do
    quote generated: true do
      @ogol_sequence Ogol.Sequence.Normalize.from_dsl!(@spark_dsl_config, __MODULE__)

      def __ogol_sequence__, do: @ogol_sequence
    end
  end
end
