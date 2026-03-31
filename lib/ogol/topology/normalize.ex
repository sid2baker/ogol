defmodule Ogol.Topology.Normalize do
  @moduledoc false

  alias Ogol.Topology.Dsl
  alias Ogol.Topology.Model
  alias Spark.Dsl.Verifier

  @spec from_dsl!(map(), module()) :: Model.t()
  def from_dsl!(dsl_state, module) do
    strategy = Verifier.get_option(dsl_state, [:topology], :strategy, :one_for_one)
    meaning = Verifier.get_option(dsl_state, [:topology], :meaning)
    machines = Verifier.get_entities(dsl_state, [:machines])

    %Model{
      module: module,
      topology_id: module_name(module),
      strategy: strategy,
      meaning: meaning,
      machines: Enum.map(machines, &normalize_machine/1)
    }
  end

  defp module_name(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp normalize_machine(%Dsl.Machine{} = machine) do
    %{
      name: machine.name,
      module: machine.module,
      opts: machine.opts || [],
      restart: machine.restart || :permanent,
      meaning: machine.meaning
    }
  end
end
