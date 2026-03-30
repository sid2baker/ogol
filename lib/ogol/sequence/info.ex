defmodule Ogol.Sequence.Info do
  @moduledoc """
  Introspection helpers for the Ogol Sequence Spark DSL.
  """

  use Spark.InfoGenerator,
    extension: Ogol.Sequence.Dsl,
    sections: [:sequence]

  alias Ogol.Sequence.Dsl
  alias Spark.Dsl.Extension

  @step_modules [Dsl.DoSkill, Dsl.Wait, Dsl.Run, Dsl.Repeat, Dsl.Fail]

  @spec sequence_option(module(), atom(), term()) :: term()
  def sequence_option(module, name, default \\ nil) do
    Extension.get_opt(module, [:sequence], name, default)
  end

  @spec sequence_items(module()) :: [struct()]
  def sequence_items(module), do: Extension.get_entities(module, [:sequence])

  @spec invariants(module()) :: [struct()]
  def invariants(module), do: Enum.filter(sequence_items(module), &match?(%Dsl.Invariant{}, &1))

  @spec procedures(module()) :: [struct()]
  def procedures(module), do: Enum.filter(sequence_items(module), &match?(%Dsl.Proc{}, &1))

  @spec root_steps(module()) :: [struct()]
  def root_steps(module) do
    sequence_items(module)
    |> Enum.filter(fn item ->
      Enum.any?(@step_modules, fn mod -> match?(%{__struct__: ^mod}, item) end)
    end)
  end

  @spec canonical_model(module()) :: Ogol.Sequence.Model.t()
  def canonical_model(module), do: module.__ogol_sequence__()
end
