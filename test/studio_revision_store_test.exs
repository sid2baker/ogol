defmodule Ogol.Studio.RevisionStoreTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Bundle
  alias Ogol.Driver.Source, as: DriverSource
  alias Ogol.HMI.HardwareGateway
  alias Ogol.Studio.RevisionStore
  alias Ogol.Studio.WorkspaceStore
  alias Ogol.Topology.Registry

  test "deploys immutable revision snapshots without mutating the working drafts" do
    revision_model =
      DriverSource.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Revision")

    WorkspaceStore.save_driver_source(
      "packaging_outputs",
      DriverSource.to_source(
        DriverSource.module_from_name!(revision_model.module_name),
        revision_model
      ),
      revision_model,
      :synced,
      []
    )

    assert {:ok,
            %RevisionStore.Revision{
              id: "r1",
              topology_id: "packaging_line",
              hardware_config_id: "ethercat_demo",
              source: source
            }} =
             RevisionStore.deploy_current(app_id: "ogol_bundle")

    assert %{root: :packaging_line} = Registry.active_topology()
    assert HardwareGateway.ethercat_master_running?()

    draft_model =
      DriverSource.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Draft")

    WorkspaceStore.save_driver_source(
      "packaging_outputs",
      DriverSource.to_source(
        DriverSource.module_from_name!(draft_model.module_name),
        draft_model
      ),
      draft_model,
      :synced,
      []
    )

    assert WorkspaceStore.fetch_driver("packaging_outputs").model.label ==
             "Packaging Outputs Draft"

    assert {:ok, bundle} = Bundle.import(source)

    assert Bundle.artifact(bundle, :driver, "packaging_outputs").model.label ==
             "Packaging Outputs Revision"

    assert WorkspaceStore.fetch_driver("packaging_outputs").model.label ==
             "Packaging Outputs Draft"
  end
end
