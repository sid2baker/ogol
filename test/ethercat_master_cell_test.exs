defmodule Ogol.Studio.EthercatMasterCellTest do
  use ExUnit.Case, async: true

  alias Ogol.Studio.Cell
  alias Ogol.Studio.EthercatMasterCell

  test "runtime request falls back to visual when the master is idle" do
    facts =
      EthercatMasterCell.facts_from_assigns(%{
        ethercat: %{master_status: %{lifecycle: :idle}, state: {:ok, :idle}},
        hardware_context: %{observed: %{source: :none}},
        hardware_feedback: nil,
        requested_master_view: :runtime,
        master_cell_source: "master_cell do end",
        simulation_config_form: %{}
      })

    derived = Cell.derive(EthercatMasterCell, facts)

    assert derived.selected_view == :visual
    assert Enum.any?(derived.views, &(&1.id == :runtime and not &1.available?))
    assert Enum.map(derived.actions, & &1.id) == [:scan_master, :start_master]
  end

  test "running master exposes the runtime view and stop action" do
    facts =
      EthercatMasterCell.facts_from_assigns(%{
        ethercat: %{master_status: %{lifecycle: :operational}, state: {:ok, :operational}},
        hardware_context: %{observed: %{source: :simulator}},
        hardware_feedback: nil,
        requested_master_view: :runtime,
        master_cell_source: "master_cell do end",
        simulation_config_form: %{}
      })

    derived = Cell.derive(EthercatMasterCell, facts)

    assert derived.selected_view == :runtime
    assert Enum.any?(derived.views, &(&1.id == :runtime and &1.available?))
    assert Enum.map(derived.actions, & &1.id) == [:stop_master]
  end
end
