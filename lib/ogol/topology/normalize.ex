defmodule Ogol.Topology.Normalize do
  @moduledoc false

  alias Ogol.Topology.Dsl
  alias Ogol.Topology.Model
  alias Ogol.Topology.Wiring
  alias Spark.Dsl.Verifier

  @spec from_dsl!(map(), module()) :: Model.t()
  def from_dsl!(dsl_state, module) do
    strategy = Verifier.get_option(dsl_state, [:topology], :strategy, :one_for_one)
    meaning = Verifier.get_option(dsl_state, [:topology], :meaning)
    machines = Verifier.get_entities(dsl_state, [:machines])

    %Model{
      module: module,
      strategy: strategy,
      meaning: meaning,
      machines: Enum.map(machines, &normalize_machine/1)
    }
  end

  defp normalize_machine(%Dsl.Machine{} = machine) do
    wiring =
      case Wiring.normalize(machine.wiring) do
        {:ok, normalized} -> normalized
        {:error, _reason} -> %Wiring{}
      end

    %{
      name: machine.name,
      module: machine.module,
      opts: machine.opts || [],
      restart: machine.restart || :permanent,
      meaning: machine.meaning,
      wiring: wiring
    }
  end
end
