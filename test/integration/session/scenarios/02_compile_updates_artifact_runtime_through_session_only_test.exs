defmodule Ogol.Session.ArtifactRuntimeCompileScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Session
  alias Ogol.Session.Workspace.SourceDraft
  alias Ogol.Studio.Build

  test "compile updates session-owned artifact runtime only when compile runs" do
    assert {:error, :not_found} = Session.runtime_status(:machine, "clamp_station")
    assert {:error, :not_found} = Session.runtime_current(:machine, "clamp_station")

    draft = Session.fetch_machine("clamp_station")

    source_v1 =
      String.replace(
        draft.source,
        ~s|meaning("Clamp station")|,
        ~s|meaning("Clamp station tuned v1")|,
        global: false
      )

    assert {:ok, model_v1} = MachineSource.from_source(source_v1)

    assert %SourceDraft{id: "clamp_station"} =
             Session.save_machine_source("clamp_station", source_v1, model_v1, :synced, [])

    digest_v1 = Build.digest(source_v1)

    assert {:error, :not_found} = Session.runtime_status(:machine, "clamp_station")
    assert {:error, :not_found} = Session.runtime_current(:machine, "clamp_station")

    assert :ok = Session.dispatch({:compile_artifact, :machine, "clamp_station"})

    assert {:ok, status_v1} = Session.runtime_status(:machine, "clamp_station")

    assert {:ok, Ogol.Generated.Machines.ClampStation} =
             Session.runtime_current(:machine, "clamp_station")

    assert status_v1.module == Ogol.Generated.Machines.ClampStation
    assert status_v1.source_digest == digest_v1
    assert status_v1.blocked_reason == nil
    assert status_v1.diagnostics == []

    source_v2 =
      String.replace(
        source_v1,
        ~s|meaning("Clamp station tuned v1")|,
        ~s|meaning("Clamp station tuned v2")|,
        global: false
      )

    assert {:ok, model_v2} = MachineSource.from_source(source_v2)

    assert %SourceDraft{id: "clamp_station"} =
             Session.save_machine_source("clamp_station", source_v2, model_v2, :synced, [])

    digest_v2 = Build.digest(source_v2)

    assert {:ok, stale_status} = Session.runtime_status(:machine, "clamp_station")

    assert {:ok, Ogol.Generated.Machines.ClampStation} =
             Session.runtime_current(:machine, "clamp_station")

    assert stale_status.source_digest == digest_v1
    assert stale_status.source_digest != digest_v2

    assert :ok = Session.dispatch({:compile_artifact, :machine, "clamp_station"})

    assert {:ok, status_v2} = Session.runtime_status(:machine, "clamp_station")

    assert {:ok, Ogol.Generated.Machines.ClampStation} =
             Session.runtime_current(:machine, "clamp_station")

    assert status_v2.source_digest == digest_v2
    assert status_v2.blocked_reason == nil
    assert status_v2.diagnostics == []
    assert Session.fetch_machine("clamp_station").source == source_v2
  end
end
