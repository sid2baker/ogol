defmodule Ogol.Topology.Normalize do
  @moduledoc false

  alias Ogol.Topology.Dsl
  alias Ogol.Topology.Model
  alias Spark.Dsl.Verifier

  @spec from_dsl!(map(), module()) :: Model.t()
  def from_dsl!(dsl_state, module) do
    root = Verifier.get_option(dsl_state, [:topology], :root)
    strategy = Verifier.get_option(dsl_state, [:topology], :strategy, :one_for_one)
    meaning = Verifier.get_option(dsl_state, [:topology], :meaning)
    machines = Verifier.get_entities(dsl_state, [:machines])
    observations = Verifier.get_entities(dsl_state, [:observations])

    %Model{
      module: module,
      root: root,
      strategy: strategy,
      meaning: meaning,
      machines: Enum.map(machines, &normalize_machine/1),
      observations: normalize_observations(observations)
    }
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

  defp normalize_observations(observations) do
    observations
    |> Enum.group_by(& &1.source)
    |> Enum.map(fn {source, items} ->
      Enum.reduce(
        items,
        %{
          name: source,
          state_bindings: [],
          signal_bindings: [],
          status_bindings: [],
          down_binding: nil
        },
        fn
          %Dsl.ObserveState{state: state, as: binding}, acc ->
            %{acc | state_bindings: acc.state_bindings ++ [{state, binding}]}

          %Dsl.ObserveSignal{signal: signal, as: binding}, acc ->
            %{acc | signal_bindings: acc.signal_bindings ++ [{signal, binding}]}

          %Dsl.ObserveStatus{item: item, as: binding}, acc ->
            %{acc | status_bindings: acc.status_bindings ++ [{item, binding}]}

          %Dsl.ObserveDown{as: binding}, acc ->
            %{acc | down_binding: binding}
        end
      )
    end)
    |> Enum.sort_by(& &1.name)
  end
end
