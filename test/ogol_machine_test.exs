defmodule OgolMachineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Ogol.Machine.Info
  alias Ogol.TestSupport.SampleMachine

  test "info exposes declared boundary and state data" do
    assert [fact] = Info.facts(SampleMachine)
    assert fact.name == :guard_closed?

    assert [request] = Info.requests(SampleMachine)
    assert request.name == :start

    assert [command] = Info.commands(SampleMachine)
    assert command.name == :start_motor

    assert [output] = Info.outputs(SampleMachine)
    assert output.name == :running?

    assert [signal] = Info.signals(SampleMachine)
    assert signal.name == :started

    assert [field] = Info.fields(SampleMachine)
    assert field.name == :retry_count

    assert [idle, running] = Info.states(SampleMachine)
    assert idle.initial?
    refute running.initial?

    assert [%_{} = transition] = Info.transitions(SampleMachine)
    assert transition.source == :idle
    assert transition.destination == :running
    assert transition.on == {:request, :start}
  end

  test "verifier reports missing initial state" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule Ogol.TestSupport.NoInitialMachine do
          use Ogol.Machine

          boundary do
            request :start
          end

          states do
            state :idle
            state :running
          end
        end
        """)
      end)

    assert output =~ "exactly one state must be marked `initial?: true`"
  end

  test "verifier reports actions targeting undeclared outputs" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule Ogol.TestSupport.InvalidActionTargetMachine do
          use Ogol.Machine

          boundary do
            request :start
          end

          states do
            state :idle do
              initial? true
            end

            state :running
          end

          transitions do
            transition :idle, :running do
              on {:request, :start}
              set_output :missing_output, true
            end
          end
        end
        """)
      end)

    assert output =~ "references unknown output :missing_output"
  end

  test "verifier rejects bare request-only triggers" do
    output =
      capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule Ogol.TestSupport.BareRequestTriggerMachine do
          use Ogol.Machine

          boundary do
            request :start
          end

          states do
            state :idle do
              initial? true
            end

            state :running
          end

          transitions do
            transition :idle, :running do
              on :start
              reply :ok
            end
          end
        end
        """)
      end)

    assert output =~ "bare trigger :start for a request-only boundary"
    assert output =~ "on({:request, :start})"
  end

  test "machine DSL no longer accepts children blocks" do
    output =
      capture_io(:stderr, fn ->
        assert_raise CompileError, fn ->
          Code.compile_string("""
          defmodule Ogol.TestSupport.LegacyChildrenMachine do
            use Ogol.Machine

            states do
              state :idle do
                initial? true
              end
            end

            children do
              child :worker, Ogol.TestSupport.SampleMachine
            end
          end
          """)
        end
      end)

    assert output =~ "undefined function children/1"
  end
end
