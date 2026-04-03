defmodule Ogol.MachineGraphTest do
  use ExUnit.Case, async: true

  alias Ogol.Machine.Graph

  test "generates compact mermaid output for simple machine models" do
    model = %{
      states: [
        %{name: "idle", status: "Idle", meaning: "", initial?: true},
        %{name: "running", status: "Running", meaning: "", initial?: false},
        %{name: "faulted", status: "Faulted", meaning: "", initial?: false}
      ],
      transitions: [
        %{source: "idle", destination: "running", family: "request", trigger: "start"},
        %{source: "running", destination: "idle", family: "request", trigger: "stop"},
        %{source: "faulted", destination: "idle", family: "request", trigger: "reset"}
      ]
    }

    diagram = Graph.mermaid(model)

    assert diagram =~ "stateDiagram-v2"
    refute diagram =~ "direction LR"
    assert diagram =~ ~s(state "idle" as state_idle)
    assert diagram =~ ~s(state "running" as state_running)
    assert diagram =~ "state_idle --> state_running : start"
    refute diagram =~ "request:start"
    refute diagram =~ "idle / Idle"
  end
end
