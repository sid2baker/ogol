defmodule Ogol.Machine.Info do
  @moduledoc """
  Introspection helpers for the Ogol Spark DSL.
  """

  use Spark.InfoGenerator,
    extension: Ogol.Machine.Dsl,
    sections: [:machine, :uses, :boundary, :memory, :states, :transitions, :safety]

  alias Ogol.Machine.Dsl
  alias Spark.Dsl.Extension

  @spec machine_option(module(), atom(), term()) :: term()
  def machine_option(module, name, default \\ nil) do
    Extension.get_opt(module, [:machine], name, default)
  end

  @spec boundary_items(module()) :: [struct()]
  def boundary_items(module), do: Extension.get_entities(module, [:boundary])

  @spec facts(module()) :: [Dsl.Fact.t()]
  def facts(module), do: Enum.filter(boundary_items(module), &match?(%Dsl.Fact{}, &1))

  @spec events(module()) :: [Dsl.Event.t()]
  def events(module), do: Enum.filter(boundary_items(module), &match?(%Dsl.Event{}, &1))

  @spec requests(module()) :: [Dsl.Request.t()]
  def requests(module), do: Enum.filter(boundary_items(module), &match?(%Dsl.Request{}, &1))

  @spec commands(module()) :: [Dsl.Command.t()]
  def commands(module), do: Enum.filter(boundary_items(module), &match?(%Dsl.Command{}, &1))

  @spec outputs(module()) :: [Dsl.Output.t()]
  def outputs(module), do: Enum.filter(boundary_items(module), &match?(%Dsl.Output{}, &1))

  @spec signals(module()) :: [Dsl.Signal.t()]
  def signals(module), do: Enum.filter(boundary_items(module), &match?(%Dsl.Signal{}, &1))

  @spec fields(module()) :: [Dsl.Field.t()]
  def fields(module), do: Extension.get_entities(module, [:memory])

  @spec states(module()) :: [Dsl.State.t()]
  def states(module), do: Extension.get_entities(module, [:states])

  @spec transitions(module()) :: [Dsl.Transition.t()]
  def transitions(module), do: Extension.get_entities(module, [:transitions])

  @spec safety_rules(module()) :: [struct()]
  def safety_rules(module), do: Extension.get_entities(module, [:safety])

  @spec dependencies(module()) :: [Dsl.Dependency.t()]
  def dependencies(module), do: Extension.get_entities(module, [:uses])
end
