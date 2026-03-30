defmodule Ogol.Compiler.Model.Machine do
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
    dependencies: MapSet.new(),
    states: %{},
    transitions_by_source: %{},
    safety_rules: []
  ]
end
