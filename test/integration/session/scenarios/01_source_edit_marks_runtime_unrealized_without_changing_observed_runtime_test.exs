defmodule Ogol.Session.SourceEditWhileLiveScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Machine.Source, as: MachineSource
  alias Ogol.Session
  alias Ogol.TestSupport.EthercatHmiFixture

  test "editing workspace source marks runtime unrealized without changing observed runtime" do
    EthercatHmiFixture.boot_simulator_only!()

    assert :ok = Session.set_desired_runtime({:running, :live})

    assert %{topology_scope: :packaging_line} = Ogol.Topology.Registry.active_topology()
    assert Session.runtime_realized?()
    refute Session.runtime_dirty?()

    runtime_before = Session.runtime_state()

    assert runtime_before.desired == {:running, :live}
    assert runtime_before.observed == {:running, :live}
    assert runtime_before.status == :running
    assert is_binary(runtime_before.deployment_id)
    assert is_binary(runtime_before.realized_workspace_hash)

    draft = Session.fetch_machine("clamp_station")

    updated_source =
      String.replace(
        draft.source,
        ~s|meaning("Clamp station")|,
        ~s|meaning("Clamp station retuned")|,
        global: false
      )

    assert {:ok, updated_model} = MachineSource.from_source(updated_source)

    assert %Ogol.Session.Workspace.SourceDraft{id: "clamp_station"} =
             Session.save_machine_source(
               "clamp_station",
               updated_source,
               updated_model,
               :synced,
               []
             )

    runtime_after = Session.runtime_state()
    updated_draft = Session.fetch_machine("clamp_station")

    assert updated_draft.source =~ ~s|meaning("Clamp station retuned")|
    assert runtime_after.desired == {:running, :live}
    assert runtime_after.observed == {:running, :live}
    assert runtime_after.status == :running
    assert runtime_after.deployment_id == runtime_before.deployment_id
    assert runtime_after.realized_workspace_hash == runtime_before.realized_workspace_hash
    assert runtime_after.trust_state == :invalidated
    assert runtime_after.invalidation_reasons == [:workspace_changed]
    assert %{topology_scope: :packaging_line} = Ogol.Topology.Registry.active_topology()
    refute Session.runtime_realized?()
    assert Session.runtime_dirty?()
  end
end
