defmodule Ogol.Studio.ModulesTest do
  use ExUnit.Case, async: false

  alias Ogol.Studio.Build
  alias Ogol.Studio.ModuleStatusStore
  alias Ogol.Studio.Modules

  setup do
    ModuleStatusStore.reset()
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

  test "apply loads the artifact and exposes current/status" do
    module = unique_module("ApplyCurrent")
    source = plain_module_source(module, 1)

    assert {:ok, artifact} = Build.build("apply_current", module, source)
    assert {:ok, %{module: ^module, status: :applied}} = Modules.apply("apply_current", artifact)
    assert {:ok, ^module} = Modules.current("apply_current")

    assert {:ok, status} = Modules.status("apply_current")
    assert status.module == module
    assert status.apply_state == :applied
    assert status.source_digest == artifact.source_digest
  end

  test "apply blocks when old code is still in use" do
    module = unique_module("Draining")

    assert {:ok, artifact_v1} =
             Build.build("draining_driver", module, lingering_module_source(module, 1))

    assert {:ok, _} = Modules.apply("draining_driver", artifact_v1)

    parent = self()

    linger_pid =
      spawn_link(fn ->
        apply(module, :linger, [parent])
      end)

    assert_receive {:lingering, ^linger_pid, 1}

    assert {:ok, artifact_v2} =
             Build.build("draining_driver", module, lingering_module_source(module, 2))

    assert {:ok, _} = Modules.apply("draining_driver", artifact_v2)
    assert apply(module, :version, []) == 2

    assert {:ok, artifact_v3} =
             Build.build("draining_driver", module, lingering_module_source(module, 3))

    assert {:blocked, %{reason: :old_code_in_use, module: ^module, pids: pids}} =
             Modules.apply("draining_driver", artifact_v3)

    assert linger_pid in pids

    assert {:ok, status} = Modules.status("draining_driver")
    assert status.apply_state == :blocked
    assert status.blocked_reason == :old_code_in_use
    assert linger_pid in status.lingering_pids

    send(linger_pid, :stop)
  end

  test "apply rejects an artifact whose module does not match the logical id registry entry" do
    first_module = unique_module("PackagingOutputs")
    second_module = unique_module("PackagingOutputsRenamed")

    assert {:ok, first_artifact} =
             Build.build("shared_driver", first_module, plain_module_source(first_module, 1))

    assert {:ok, _} = Modules.apply("shared_driver", first_artifact)

    assert {:ok, second_artifact} =
             Build.build("shared_driver", second_module, plain_module_source(second_module, 2))

    assert {:error, {:module_mismatch, ^first_module, ^second_module}} =
             Modules.apply("shared_driver", second_artifact)
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
