defmodule TopologyDslTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "topology requires at least one machine" do
    topology_module = unique_module("EmptyTopology")

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            strategy(:one_for_one)
          end
        end
        """)
      end)

    assert output =~ "topology must declare at least one machine"
  end

  test "topology rejects unloaded machine modules" do
    topology_module = unique_module("UnloadedMachineTopology")

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            strategy(:one_for_one)
          end

          machines do
            machine(:line, Ogol.Does.Not.Exist)
          end
        end
        """)
      end)

    assert output =~ "references unloaded module Ogol.Does.Not.Exist"
  end

  test "topology rejects non-machine modules in machine declarations" do
    plain_module = unique_module("PlainModule")
    topology_module = unique_module("NonMachineTopology")

    compile_source("""
    defmodule #{inspect(plain_module)} do
      def hello, do: :world
    end
    """)

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            strategy(:one_for_one)
          end

          machines do
            machine(:line, #{inspect(plain_module)})
          end
        end
        """)
      end)

    assert output =~ "does not expose Ogol machine metadata"
  end

  test "topology allows duplicate machine modules with distinct instance names" do
    topology_module = unique_module("DuplicateModuleTopology")

    Code.compile_string("""
    defmodule #{inspect(topology_module)} do
      use Ogol.Topology

      topology do
        strategy(:one_for_one)
      end

      machines do
        machine(:primary_clamp, Ogol.TestSupport.ClampDependencyMachine)
        machine(:backup_clamp, Ogol.TestSupport.ClampDependencyMachine)
      end
    end
    """)

    assert function_exported?(topology_module, :__ogol_topology__, 0)
  end

  test "topology rejects wiring that targets undeclared machine ports" do
    topology_module = unique_module("InvalidWiringTopology")

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            strategy(:one_for_one)
          end

          machines do
            machine(:primary_clamp, Ogol.TestSupport.ClampDependencyMachine,
              wiring: [outputs: [missing_output: :missing_output]]
            )
          end
        end
        """)
      end)

    assert output =~ "machine wiring references unknown output :missing_output"
  end

  test "topology rejects nested topology modules in machines" do
    line_module = unique_module("NestedTopologyLine")
    inner_topology_module = unique_module("InnerTopology")
    outer_topology_module = unique_module("OuterTopology")

    compile_source("""
    defmodule #{inspect(line_module)} do
      use Ogol.Machine

      states do
        state :idle do
          initial?(true)
        end
      end
    end
    """)

    compile_source("""
    defmodule #{inspect(inner_topology_module)} do
      use Ogol.Topology

      topology do
        strategy(:one_for_one)
      end

      machines do
        machine(:line, #{inspect(line_module)})
      end
    end
    """)

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(outer_topology_module)} do
          use Ogol.Topology

          topology do
            strategy(:one_for_one)
          end

          machines do
            machine(:outer_line, #{inspect(line_module)})
            machine(:nested, #{inspect(inner_topology_module)})
          end
        end
        """)
      end)

    assert output =~ "nested topologies are not supported"
  end

  defp unique_module(prefix) do
    Module.concat([Ogol, TestSupport, :"#{prefix}#{System.unique_integer([:positive])}"])
  end

  defp compile_source(source) do
    Code.compile_string(source)
  end
end
