defmodule Ogol.Sequence.Ref do
  @moduledoc """
  Helpers for building typed references in Sequence DSL source.
  """

  alias Ogol.Sequence.Model

  @spec skill(atom(), atom()) :: struct()
  def skill(machine, skill), do: %Model.SkillRef{machine: machine, skill: skill}

  @spec status(atom(), atom()) :: struct()
  def status(machine, item), do: %Model.StatusRef{machine: machine, item: item}

  @spec signal(atom(), atom()) :: struct()
  def signal(machine, item), do: %Model.SignalRef{machine: machine, item: item}

  @spec topology(atom()) :: struct()
  def topology(item), do: %Model.TopologyRef{scope: :system, item: item}
end
