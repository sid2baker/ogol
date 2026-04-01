defmodule Ogol.Machine.Compiler.Interface do
  @moduledoc false

  alias Ogol.Interface
  alias Ogol.Machine.Dsl
  alias Ogol.Machine.Skill
  alias Ogol.StatusSpec
  alias Spark.Dsl.Verifier

  @spec from_dsl!(map(), Ogol.Machine.Compiler.Model.Machine.t(), module()) :: Interface.t()
  def from_dsl!(dsl_state, machine, module) do
    boundary = Verifier.get_entities(dsl_state, [:boundary])
    fields = Verifier.get_entities(dsl_state, [:memory])

    %Interface{
      machine_id: machine.name,
      module: module,
      summary: machine.meaning,
      skills: build_skills(boundary),
      signals: build_signals(boundary),
      status_spec: %StatusSpec{
        facts: public_items(boundary, Dsl.Fact),
        outputs: public_items(boundary, Dsl.Output),
        fields: public_items(fields, Dsl.Field)
      }
    }
  end

  defp build_skills(boundary) do
    boundary
    |> Enum.flat_map(fn
      %Dsl.Request{name: name, meaning: meaning, skill?: skill?, args: args} ->
        if skill? == false do
          []
        else
          [
            %Skill{
              name: name,
              kind: :request,
              summary: meaning,
              args: build_skill_args(args),
              returns: :reply,
              visible?: true
            }
          ]
        end

      %Dsl.Event{name: name, meaning: meaning, skill?: true, args: args} ->
        [
          %Skill{
            name: name,
            kind: :event,
            summary: meaning,
            args: build_skill_args(args),
            returns: :accepted,
            visible?: true
          }
        ]

      _other ->
        []
    end)
    |> Enum.sort_by(&to_string(&1.name))
  end

  defp build_skill_args(args) when is_list(args) do
    Enum.map(args, fn {name, opts} ->
      opts
      |> Enum.into(%{})
      |> Map.put(:name, name)
    end)
  end

  defp build_skill_args(_other), do: []

  defp build_signals(boundary) do
    boundary
    |> Enum.flat_map(fn
      %Dsl.Signal{name: name, meaning: meaning} ->
        [%{name: name, summary: meaning}]

      _other ->
        []
    end)
    |> Enum.sort_by(&to_string(&1.name))
  end

  defp public_items(items, module) do
    items
    |> Enum.flat_map(fn
      %{__struct__: ^module, name: name, meaning: meaning, public?: true} ->
        [%{name: name, summary: meaning}]

      _other ->
        []
    end)
    |> Enum.sort_by(&to_string(&1.name))
  end
end
