defmodule Ogol.HMI.HardwareDiffTest do
  use ExUnit.Case, async: false

  alias Ogol.HMI.{HardwareDiff, HardwareGateway}
  alias Ogol.TestSupport.EthercatHmiFixture

  setup do
    EthercatHmiFixture.stop_all!()

    on_exit(fn ->
      EthercatHmiFixture.stop_all!()
    end)

    :ok
  end

  test "reports aligned when the staged draft matches the live hardware preview" do
    EthercatHmiFixture.boot_preop_ring!()

    draft = HardwareGateway.default_ethercat_simulation_form()
    assert {:ok, preview} = HardwareGateway.preview_ethercat_hardware_config()

    diff = HardwareDiff.compare_draft_to_live(draft, preview)

    assert diff.status == :aligned
    assert diff.summary == "Draft matches the live hardware preview."
    assert diff.draft_only_domains == []
    assert diff.live_only_domains == []
    assert diff.domain_mismatches == []
    assert diff.draft_only_slaves == []
    assert diff.live_only_slaves == []
    assert diff.slave_mismatches == []
  end

  test "reports missing live slaves and field mismatches" do
    EthercatHmiFixture.boot_preop_ring!()

    draft =
      HardwareGateway.default_ethercat_simulation_form()
      |> Map.put("slaves", [
        %{
          "name" => "coupler",
          "driver" => "EtherCAT.Driver.EK1100",
          "target_state" => "op",
          "process_data_mode" => "none",
          "process_data_domain" => "main",
          "health_poll_ms" => ""
        },
        %{
          "name" => "inputs",
          "driver" => "EtherCAT.Driver.EL1809",
          "target_state" => "preop",
          "process_data_mode" => "all",
          "process_data_domain" => "main",
          "health_poll_ms" => ""
        }
      ])

    assert {:ok, preview} = HardwareGateway.preview_ethercat_hardware_config()

    diff = HardwareDiff.compare_draft_to_live(draft, preview)

    assert diff.status == :different
    assert diff.draft_only_slaves == []
    assert diff.live_only_slaves == ["outputs"]
    assert diff.slave_mismatches == ["inputs: target_state: draft=preop live=op"]
  end
end
