defmodule Ogol.Session.CanonicalHardwareLiveScenarioTest do
  use Ogol.SessionIntegrationCase, async: false

  alias Ogol.Hardware.EtherCAT.Driver.EK1100
  alias Ogol.Hardware.EtherCAT.Driver.EL1809
  alias Ogol.Hardware.EtherCAT.Driver.EL2809
  alias Ogol.Hardware.EtherCAT.DriverLibrary
  alias Ogol.Session
  alias Ogol.Studio.Build
  alias Ogol.TestSupport.EthercatHmiFixture

  @example_id "pump_skid_commissioning_bench"

  test "canonical hardware compile and live reconcile stay session-owned" do
    on_exit(fn -> EthercatHmiFixture.stop_all!() end)

    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()

    assert hardware_draft = Session.fetch_hardware("ethercat")
    assert hardware_draft.source =~ "defmodule Ogol.Generated.Hardware.EtherCAT do"
    assert hardware_draft.source =~ "use Ogol.Hardware"
    refute hardware_draft.source =~ "Ogol.Generated.Hardware.Config.EtherCAT"

    source_digest = Build.digest(hardware_draft.source)

    assert {:error, :not_found} = Session.runtime_status(:hardware, "ethercat")
    assert {:error, :not_found} = Session.runtime_current(:hardware, "ethercat")

    assert :ok = Session.dispatch({:compile_artifact, :hardware, "ethercat"})

    assert {:ok, status} = Session.runtime_status(:hardware, "ethercat")

    assert {:ok, Ogol.Generated.Hardware.EtherCAT} =
             Session.runtime_current(:hardware, "ethercat")

    assert status.module == Ogol.Generated.Hardware.EtherCAT
    assert status.source_digest == source_digest
    assert status.blocked_reason == nil
    assert status.diagnostics == []

    EthercatHmiFixture.boot_workspace_simulator!()

    assert :ok = Session.set_desired_runtime({:running, :live})

    assert_eventually(fn ->
      runtime = Session.runtime_state()

      assert runtime.desired == {:running, :live}
      assert runtime.observed == {:running, :live}
      assert runtime.status == :running
      assert runtime.active_topology_module == Ogol.Generated.Topologies.PumpSkidBench
      assert runtime.active_adapters == [:ethercat]
      assert is_binary(runtime.deployment_id)
      assert runtime.last_error == nil
      assert Session.runtime_realized?()
      refute Session.runtime_dirty?()

      assert {:ok, live_status} = Session.runtime_status(:hardware, "ethercat")

      assert {:ok, Ogol.Generated.Hardware.EtherCAT} =
               Session.runtime_current(:hardware, "ethercat")

      assert live_status.module == Ogol.Generated.Hardware.EtherCAT
      assert live_status.source_digest == source_digest
      assert live_status.blocked_reason == nil
      assert live_status.diagnostics == []
    end)
  end

  test "hardware compile recompiles the referenced ethercat drivers" do
    on_exit(fn ->
      DriverLibrary.ensure_loaded()
      EthercatHmiFixture.stop_all!()
    end)

    assert {:ok, _example, _revision_file, %{mode: :initial}} =
             Session.load_example(@example_id)

    put_udp_hardware!()

    purge_driver!(EK1100)
    purge_driver!(EL1809)
    purge_driver!(EL2809)

    refute driver_loaded?(EK1100)
    refute driver_loaded?(EL1809)
    refute driver_loaded?(EL2809)

    assert :ok = Session.dispatch({:compile_artifact, :hardware, "ethercat"})

    assert Code.ensure_loaded?(EK1100)
    assert Code.ensure_loaded?(Module.concat(EK1100, "Simulator"))
    assert Code.ensure_loaded?(EL1809)
    assert Code.ensure_loaded?(Module.concat(EL1809, "Simulator"))
    assert Code.ensure_loaded?(EL2809)
    assert Code.ensure_loaded?(Module.concat(EL2809, "Simulator"))
  end

  defp put_udp_hardware! do
    config = Session.fetch_hardware_model("ethercat")

    Session.put_hardware(%{
      config
      | transport: %{
          config.transport
          | mode: :udp,
            bind_ip: {127, 0, 0, 1},
            primary_interface: nil,
            secondary_interface: nil
        }
    })
  end

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, 0), do: fun.()

  defp assert_eventually(fun, attempts) do
    fun.()
  rescue
    _error in [ExUnit.AssertionError, MatchError] ->
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
  end

  defp purge_driver!(module) when is_atom(module) do
    Enum.each([module, Module.concat(module, "Simulator")], fn current ->
      _ = :code.purge(current)
      _ = :code.delete(current)
    end)
  end

  defp driver_loaded?(module) when is_atom(module) do
    match?({:file, _path}, :code.is_loaded(module))
  end
end
