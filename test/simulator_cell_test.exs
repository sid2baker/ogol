defmodule Ogol.Studio.SimulatorCellTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.Cell
  alias Ogol.Studio.SimulatorCell

  test "running simulator exposes stop action and keeps visual selected" do
    facts =
      SimulatorCell.facts_from_assigns(%{
        simulation_config_id: "ethercat_demo",
        simulation_source: "simulator_cell do end",
        effective_simulation_config: %{},
        simulation_config_form: %{},
        requested_view: :visual,
        hardware_feedback: nil,
        hardware_context: %{
          mode: %{kind: :testing, write_policy: :enabled, authority_scope: :studio},
          observed: %{source: :simulator}
        }
      })

    derived = Cell.derive(SimulatorCell, facts)

    assert derived.selected_view == :visual
    assert Enum.map(derived.actions, & &1.id) == [:stop_simulation]
  end

  test "blocked write policy disables transitions and surfaces a warning notice" do
    facts =
      SimulatorCell.facts_from_assigns(%{
        simulation_config_id: "ethercat_demo",
        simulation_source: "simulator_cell do end",
        effective_simulation_config: %{},
        simulation_config_form: %{},
        requested_view: :visual,
        hardware_feedback: nil,
        hardware_context: %{
          mode: %{kind: :testing, write_policy: :disabled, authority_scope: :release},
          observed: %{source: :none}
        }
      })

    derived = Cell.derive(SimulatorCell, facts)

    assert derived.notice.title == "Simulation writes are blocked"
    assert [%{id: :start_simulation, enabled?: false}] = derived.actions
  end
end
