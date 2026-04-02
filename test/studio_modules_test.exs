defmodule Ogol.Studio.ModulesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ogol.Studio.Build
  alias Ogol.Machine.Contract, as: MachineContract
  alias Ogol.Runtime
  alias Ogol.Session

  setup do
    _ = Runtime.reset()
    :ok = Session.reset_drivers()
    :ok = Session.reset_machines()
    :ok = Session.reset_topologies()
    :ok = Session.reset_sequences()
    :ok = Session.reset_hardware_config()
    :ok = Session.reset_loaded_revision()
    {:ok, _example, _revision_file, _report} = Session.load_example("packaging_line")
    :ok = Session.reset_loaded_revision()
    :ok
  end

  test "build produces a non-loading beam artifact" do
    module = unique_module("BuildOnly")
    source = plain_module_source(module, 1)

    assert {:ok, artifact} = Build.build("build_only", module, source)
    assert artifact.module == module
    assert artifact.beam != <<>>
    refute Code.ensure_loaded?(module)
  end

  test "machine contracts are derived from the loaded module interface" do
    module = unique_module("BuiltContract")

    source = """
    defmodule #{inspect(module)} do
      use Ogol.Machine

      machine do
        name(:built_contract)
      end

      boundary do
        request(:start)
        fact(:ready?, :boolean, default: false, public?: true)
        signal(:started)
      end

      states do
        state :idle do
          initial?(true)
          set_fact(:ready?, false)
        end
      end
    end
    """

    assert {:ok, artifact} = Build.build("built_contract", module, source)
    refute Code.ensure_loaded?(module)

    assert {:ok, _result} =
             Runtime.apply_artifact(
               Runtime.artifact_id(:machine, "built_contract"),
               artifact
             )

    assert {:ok, contract} = MachineContract.from_module(module)
    assert contract.machine_id == "built_contract"
    assert Enum.any?(contract.skills, &(&1.name == "start"))
    assert Enum.any?(contract.status, &(&1.name == "ready?"))
    assert Enum.any?(contract.signals, &(&1.name == "started"))
  end

  test "machine_contract compiles the current workspace machine before describing it" do
    Session.create_machine("workspace_contract")

    source = """
    defmodule Ogol.Generated.Machines.WorkspaceContract do
      use Ogol.Machine

      machine do
        name(:workspace_contract)
      end

      boundary do
        request(:start)
        fact(:ready?, :boolean, default: false, public?: true)
        signal(:started)
      end

      states do
        state :idle do
          initial?(true)
          set_fact(:ready?, false)
        end
      end
    end
    """

    Session.save_machine_source(
      "workspace_contract",
      source,
      nil,
      :unsupported,
      []
    )

    assert {:ok, contract} =
             Runtime.machine_contract("Ogol.Generated.Machines.WorkspaceContract")

    assert contract.machine_id == "workspace_contract"
    assert Enum.any?(contract.skills, &(&1.name == "start"))
    assert Enum.any?(contract.status, &(&1.name == "ready?"))
    assert Enum.any?(contract.signals, &(&1.name == "started"))

    assert {:ok, Ogol.Generated.Machines.WorkspaceContract} =
             Runtime.current(:machine, "workspace_contract")
  end

  test "compile_topology loads referenced workspace machines before topology verification" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:ok, %{module: Ogol.Generated.Topologies.PackagingLine}} =
                 Runtime.compile(:topology, "packaging_line")
      end)

    assert {:ok, Ogol.Generated.Machines.PackagingLine} =
             Runtime.current(:machine, "packaging_line")

    assert {:ok, Ogol.Generated.Topologies.PackagingLine} =
             Runtime.current(:topology, "packaging_line")

    refute stderr =~ "references unloaded module"
  end

  test "restart_active redeploys the active topology with a new deployment id" do
    assert {:ok, %{deployment_id: first_id}} = Runtime.deploy_topology("packaging_line")
    assert %{topology_id: :packaging_line} = Ogol.Topology.Registry.active_topology()

    assert {:ok, %{deployment_id: second_id, topology_id: "packaging_line"}} =
             Runtime.restart_active()

    assert first_id != second_id
    assert %{topology_id: :packaging_line} = Ogol.Topology.Registry.active_topology()

    assert %{
             deployment_id: ^second_id,
             topology_id: "packaging_line"
           } = Runtime.active_manifest()
  end

  test "apply loads the artifact and exposes current/status" do
    module = unique_module("ApplyCurrent")
    source = plain_module_source(module, 1)

    assert {:ok, artifact} = Build.build("apply_current", module, source)
    runtime_id = Runtime.artifact_id(:driver, "apply_current")

    assert {:ok, %{module: ^module}} = Runtime.apply_artifact(runtime_id, artifact)
    assert {:ok, ^module} = Runtime.current(runtime_id)

    assert {:ok, status} = Runtime.status(runtime_id)
    assert status.module == module
    assert status.source_digest == artifact.source_digest
    assert status.blocked_reason == nil
  end

  test "apply blocks when old code is still in use" do
    module = unique_module("Draining")

    assert {:ok, artifact_v1} =
             Build.build("draining_driver", module, lingering_module_source(module, 1))

    runtime_id = Runtime.artifact_id(:driver, "draining_driver")

    assert {:ok, _} = Runtime.apply_artifact(runtime_id, artifact_v1)

    parent = self()

    linger_pid =
      spawn_link(fn ->
        apply(module, :linger, [parent])
      end)

    assert_receive {:lingering, ^linger_pid, 1}

    assert {:ok, artifact_v2} =
             Build.build("draining_driver", module, lingering_module_source(module, 2))

    assert {:ok, _} = Runtime.apply_artifact(runtime_id, artifact_v2)
    assert apply(module, :version, []) == 2

    assert {:ok, artifact_v3} =
             Build.build("draining_driver", module, lingering_module_source(module, 3))

    assert {:error, %{blocked_reason: :old_code_in_use, module: ^module, lingering_pids: pids}} =
             Runtime.apply_artifact(runtime_id, artifact_v3)

    assert linger_pid in pids

    assert {:ok, status} = Runtime.status(runtime_id)
    assert status.module == module
    assert status.blocked_reason == :old_code_in_use
    assert linger_pid in status.lingering_pids

    send(linger_pid, :stop)
  end

  test "delete_artifact unloads the compiled module and clears runtime status" do
    module = unique_module("DeleteCurrent")
    source = plain_module_source(module, 1)
    runtime_id = Runtime.artifact_id(:driver, "delete_current")

    assert {:ok, artifact} = Build.build("delete_current", module, source)
    assert {:ok, %{module: ^module}} = Runtime.apply_artifact(runtime_id, artifact)
    assert {:ok, ^module} = Runtime.current(runtime_id)

    assert {:ok, :deleted} = Runtime.delete_artifact(:driver, "delete_current")
    assert {:error, :not_found} = Runtime.current(runtime_id)
    assert {:error, :not_found} = Runtime.status(runtime_id)
    assert :code.is_loaded(module) == false
  end

  test "delete_artifact blocks when old code for the module is still in use" do
    module = unique_module("DeleteBlocked")
    runtime_id = Runtime.artifact_id(:driver, "delete_blocked")

    assert {:ok, artifact_v1} =
             Build.build("delete_blocked", module, lingering_module_source(module, 1))

    assert {:ok, %{module: ^module}} = Runtime.apply_artifact(runtime_id, artifact_v1)

    parent = self()

    linger_pid =
      spawn_link(fn ->
        apply(module, :linger, [parent])
      end)

    assert_receive {:lingering, ^linger_pid, 1}

    assert {:ok, artifact_v2} =
             Build.build("delete_blocked", module, lingering_module_source(module, 2))

    assert {:ok, %{module: ^module}} = Runtime.apply_artifact(runtime_id, artifact_v2)
    assert apply(module, :version, []) == 2

    assert {:blocked, %{blocked_reason: :old_code_in_use, module: ^module, lingering_pids: pids}} =
             Runtime.delete_artifact(:driver, "delete_blocked")

    assert linger_pid in pids

    assert {:ok, status} = Runtime.status(runtime_id)
    assert status.module == module
    assert status.blocked_reason == :old_code_in_use
    assert linger_pid in status.lingering_pids

    send(linger_pid, :stop)
  end

  test "workspace delete dispatch purges the compiled runtime artifact" do
    draft = Session.create_driver("delete_dispatch")

    assert {:ok, %{module: module}} = Runtime.compile(:driver, draft.id)
    assert {:ok, ^module} = Runtime.current(:driver, draft.id)

    assert :ok = Session.dispatch({:delete_entry, :driver, draft.id})
    assert Session.fetch_driver(draft.id) == nil
    assert {:error, :not_found} = Runtime.current(:driver, draft.id)
    assert {:error, :not_found} = Runtime.status(:driver, draft.id)
  end

  test "workspace delete dispatch keeps blocked runtime status when old code is still in use" do
    draft = Session.create_driver("delete_dispatch_blocked")
    module = unique_module("DeleteDispatchBlocked")
    runtime_id = Runtime.artifact_id(:driver, draft.id)

    assert {:ok, artifact_v1} =
             Build.build(draft.id, module, lingering_module_source(module, 1))

    assert {:ok, %{module: ^module}} = Runtime.apply_artifact(runtime_id, artifact_v1)
    assert {:ok, ^module} = Runtime.current(runtime_id)

    parent = self()

    linger_pid =
      spawn_link(fn ->
        apply(module, :linger, [parent])
      end)

    assert_receive {:lingering, ^linger_pid, 1}

    assert {:ok, artifact_v2} =
             Build.build(draft.id, module, lingering_module_source(module, 2))

    assert {:ok, %{module: ^module}} = Runtime.apply_artifact(runtime_id, artifact_v2)
    assert apply(module, :version, []) == 2

    assert :ok = Session.dispatch({:delete_entry, :driver, draft.id})
    assert Session.fetch_driver(draft.id) == nil

    assert {:ok, status} = Runtime.status(runtime_id)
    assert status.module == module
    assert status.blocked_reason == :old_code_in_use
    assert linger_pid in status.lingering_pids

    send(linger_pid, :stop)
  end

  test "building a loaded module does not emit redefine warnings" do
    module = unique_module("QuietRebuild")

    assert {:ok, artifact_v1} =
             Build.build("quiet_rebuild", module, plain_module_source(module, 1))

    assert {:ok, _} =
             Runtime.apply_artifact(
               Runtime.artifact_id(:driver, "quiet_rebuild"),
               artifact_v1
             )

    stderr =
      capture_io(:stderr, fn ->
        assert {:ok, artifact_v2} =
                 Build.build("quiet_rebuild", module, plain_module_source(module, 2))

        assert artifact_v2.module == module
      end)

    refute stderr =~ "redefining module"
  end

  test "apply rejects an artifact whose module does not match the logical id registry entry" do
    first_module = unique_module("PackagingOutputs")
    second_module = unique_module("PackagingOutputsRenamed")

    assert {:ok, first_artifact} =
             Build.build("shared_driver", first_module, plain_module_source(first_module, 1))

    runtime_id = Runtime.artifact_id(:driver, "shared_driver")

    assert {:ok, _} = Runtime.apply_artifact(runtime_id, first_artifact)

    assert {:ok, second_artifact} =
             Build.build("shared_driver", second_module, plain_module_source(second_module, 2))

    assert {:error, %{blocked_reason: {:module_mismatch, ^first_module, ^second_module}}} =
             Runtime.apply_artifact(runtime_id, second_artifact)
  end

  defp unique_module(suffix) do
    Module.concat([Ogol, TestGenerated, "#{suffix}#{System.unique_integer([:positive])}"])
  end

  defp plain_module_source(module, version) do
    """
    defmodule #{inspect(module)} do
      def version, do: #{version}
    end
    """
  end

  defp lingering_module_source(module, version) do
    """
    defmodule #{inspect(module)} do
      def version, do: #{version}

      def linger(parent) do
        send(parent, {:lingering, self(), #{version}})

        receive do
          :stop -> :ok
        end
      end
    end
    """
  end
end
