defmodule Ogol.Studio.RevisionStoreTest do
  use Ogol.ConnCase, async: false

  alias Ogol.Studio.Bundle
  alias Ogol.Studio.DriverDefinition
  alias Ogol.Studio.DriverDraftStore
  alias Ogol.Studio.RevisionStore

  test "deploys immutable revision snapshots without mutating the working drafts" do
    revision_model =
      DriverDefinition.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Revision")

    DriverDraftStore.save_source(
      "packaging_outputs",
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(revision_model.module_name),
        revision_model
      ),
      revision_model,
      :synced,
      []
    )

    assert {:ok, %RevisionStore.Revision{id: "r1", source: source}} =
             RevisionStore.deploy_current(app_id: "ogol_bundle")

    draft_model =
      DriverDefinition.default_model("packaging_outputs")
      |> Map.put(:label, "Packaging Outputs Draft")

    DriverDraftStore.save_source(
      "packaging_outputs",
      DriverDefinition.to_source(
        DriverDefinition.module_from_name!(draft_model.module_name),
        draft_model
      ),
      draft_model,
      :synced,
      []
    )

    assert DriverDraftStore.fetch("packaging_outputs").model.label == "Packaging Outputs Draft"
    assert {:ok, bundle} = Bundle.import(source)

    assert Bundle.artifact(bundle, :driver, "packaging_outputs").model.label ==
             "Packaging Outputs Revision"

    assert DriverDraftStore.fetch("packaging_outputs").model.label == "Packaging Outputs Draft"
  end
end
