defmodule Ogol.Machine.Compiler.Model.Machine do
  @moduledoc false

  defstruct [
    :module,
    :name,
    :meaning,
    :hardware_ref,
    :hardware_adapter,
    :initial_state,
    facts: %{},
    fields: %{},
    outputs: %{},
    commands: MapSet.new(),
    signals: MapSet.new(),
    events: MapSet.new(),
    requests: MapSet.new(),
    states: %{},
    transitions_by_source: %{},
    safety_rules: []
  ]
end
