defmodule TopologyDslTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "topology rejects dependencies that are not declared as machines" do
    line_module = unique_module("MissingDependencyLine")
    topology_module = unique_module("MissingDependencyTopology")

    compile_source("""
    defmodule #{inspect(line_module)} do
      use Ogol.Machine

      uses do
        dependency(:feeder, skills: [:feed_part])
      end

      states do
        state :idle do
          initial?(true)
        end
      end
    end
    """)

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            root(:line)
          end

          machines do
            machine(:line, #{inspect(line_module)})
          end
        end
        """)
      end)

    assert output =~ "declares dependency :feeder but topology does not declare that machine"
  end

  test "topology rejects dependency contracts that require unknown target skills" do
    line_module = unique_module("UnknownSkillLine")
    feeder_module = unique_module("UnknownSkillFeeder")
    topology_module = unique_module("UnknownSkillTopology")

    compile_source("""
    defmodule #{inspect(feeder_module)} do
      use Ogol.Machine

      boundary do
        request(:reset)
      end

      states do
        state :idle do
          initial?(true)
        end
      end

      transitions do
        transition :idle, :idle do
          on({:request, :reset})
          reply(:ok)
        end
      end
    end
    """)

    compile_source("""
    defmodule #{inspect(line_module)} do
      use Ogol.Machine

      uses do
        dependency(:feeder, skills: [:feed_part])
      end

      states do
        state :idle do
          initial?(true)
        end
      end
    end
    """)

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            root(:line)
          end

          machines do
            machine(:line, #{inspect(line_module)})
            machine(:feeder, #{inspect(feeder_module)})
          end
        end
        """)
      end)

    assert output =~ "requires unknown skill :feed_part"
  end

  test "topology rejects invokes outside the declared dependency skill contract" do
    line_module = unique_module("InvokeContractLine")
    feeder_module = unique_module("InvokeContractFeeder")
    topology_module = unique_module("InvokeContractTopology")

    compile_source("""
    defmodule #{inspect(feeder_module)} do
      use Ogol.Machine

      boundary do
        request(:feed_part)
        request(:reset)
      end

      states do
        state :idle do
          initial?(true)
        end
      end

      transitions do
        transition :idle, :idle do
          on({:request, :feed_part})
          reply(:ok)
        end

        transition :idle, :idle do
          on({:request, :reset})
          reply(:ok)
        end
      end
    end
    """)

    compile_source("""
    defmodule #{inspect(line_module)} do
      use Ogol.Machine

      boundary do
        request(:start)
      end

      uses do
        dependency(:feeder, skills: [:reset])
      end

      states do
        state :idle do
          initial?(true)
        end
      end

      transitions do
        transition :idle, :idle do
          on({:request, :start})
          invoke(:feeder, :feed_part)
          reply(:ok)
        end
      end
    end
    """)

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            root(:line)
          end

          machines do
            machine(:line, #{inspect(line_module)})
            machine(:feeder, #{inspect(feeder_module)})
          end
        end
        """)
      end)

    assert output =~
             "invokes skill :feed_part on dependency :feeder outside its declared uses contract"
  end

  test "topology rejects observation bindings that are not declared as root events" do
    line_module = unique_module("ObservationBindingLine")
    feeder_module = unique_module("ObservationBindingFeeder")
    topology_module = unique_module("ObservationBindingTopology")

    compile_source("""
    defmodule #{inspect(feeder_module)} do
      use Ogol.Machine

      boundary do
        signal(:part_presented)
      end

      states do
        state :idle do
          initial?(true)
        end
      end
    end
    """)

    compile_source("""
    defmodule #{inspect(line_module)} do
      use Ogol.Machine

      uses do
        dependency(:feeder, signals: [:part_presented])
      end

      boundary do
        event(:different_event)
      end

      states do
        state :idle do
          initial?(true)
        end
      end
    end
    """)

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            root(:line)
          end

          machines do
            machine(:line, #{inspect(line_module)})
            machine(:feeder, #{inspect(feeder_module)})
          end

          observations do
            observe_signal(:feeder, :part_presented, as: :feeder_ready)
          end
        end
        """)
      end)

    assert output =~
             "observation binding :feeder_ready must be declared as an event on root :line"
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
        root(:line)
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
            root(:outer_line)
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

  test "topology rejects status observations outside the root dependency status contract" do
    line_module = unique_module("StatusObservationLine")
    station_module = unique_module("StatusObservationStation")
    topology_module = unique_module("StatusObservationTopology")

    compile_source("""
    defmodule #{inspect(station_module)} do
      use Ogol.Machine

      boundary do
        output(:paired?, :boolean, default: false, public?: true)
      end

      states do
        state :idle do
          initial?(true)
          set_output(:paired?, false)
        end
      end
    end
    """)

    compile_source("""
    defmodule #{inspect(line_module)} do
      use Ogol.Machine

      uses do
        dependency(:station)
      end

      boundary do
        event(:station_ready)
      end

      states do
        state :idle do
          initial?(true)
        end
      end
    end
    """)

    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule #{inspect(topology_module)} do
          use Ogol.Topology

          topology do
            root(:line)
          end

          machines do
            machine(:line, #{inspect(line_module)})
            machine(:station, #{inspect(station_module)})
          end

          observations do
            observe_status(:station, :paired?, as: :station_ready)
          end
        end
        """)
      end)

    assert output =~ "does not declare any observed status items"
  end

  defp unique_module(prefix) do
    Module.concat([Ogol, TestSupport, :"#{prefix}#{System.unique_integer([:positive])}"])
  end

  defp compile_source(source) do
    Code.compile_string(source)
  end
end
