defmodule Ogol.SequenceDslTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Ogol.Sequence.Expr
  alias Ogol.Sequence.Info
  alias Ogol.Sequence.Model
  alias Ogol.Sequence.Ref

  defp unique_module(suffix) do
    Module.concat(__MODULE__, :"#{suffix}_#{System.unique_integer([:positive])}")
  end

  defmodule ValidSequence do
    use Ogol.Sequence

    sequence do
      name(:auto)
      topology(Ogol.TestSupport.SequenceTopology)
      meaning("Sequence DSL fixture")

      invariant(Expr.not_expr(Ref.topology(:estop)))
      invariant(Ref.status(:robot, :homed?))

      proc :startup do
        wait(Ref.status(:clamp, :closed?), timeout: 2_000, fail: "clamp failed")
        delay(25, meaning: "Observe clamp feedback")
      end

      run(:startup)

      do_skill(:clamp, :close)

      wait(Ref.status(:clamp, :closed?), timeout: 2_000, fail: "clamp failed")

      repeat do
        do_skill(:robot, :pick, when: Ref.status(:robot, :homed?))
        wait(Ref.signal(:robot, :picked), signal?: true, timeout: 5_000, fail: "robot stalled")
      end
    end
  end

  test "builds a canonical sequence model from Spark source" do
    model = ValidSequence.__ogol_sequence__()

    assert %Model{sequence: sequence} = model
    assert sequence.name == :auto
    assert sequence.topology == Ogol.TestSupport.SequenceTopology
    assert length(sequence.invariants) == 2
    assert Enum.map(sequence.procedures, & &1.name) == [:startup]

    assert [
             %Model.Step{kind: :run_procedure},
             %Model.Step{kind: :do_skill},
             %Model.Step{kind: :wait_status},
             %Model.Step{kind: :repeat, body: repeat_body}
           ] =
             sequence.root

    assert [
             %Model.Step{
               kind: :do_skill,
               guard: %Model.StatusRef{machine: :robot, item: :homed?}
             },
             %Model.Step{
               kind: :wait_signal,
               condition: %Model.SignalRef{machine: :robot, item: :picked}
             }
           ] = repeat_body
  end

  test "info module exposes authored pieces" do
    assert Info.sequence_option(ValidSequence, :name) == :auto
    assert Enum.map(Info.procedures(ValidSequence), & &1.name) == [:startup]
    assert length(Info.invariants(ValidSequence)) == 2
    assert length(Info.root_steps(ValidSequence)) == 4
  end

  test "normalizes delay steps into the canonical model" do
    [startup] = ValidSequence.__ogol_sequence__().sequence.procedures

    assert [
             %Model.Step{kind: :wait_status},
             %Model.Step{
               kind: :delay,
               duration_ms: 25,
               projection: %{label: "Observe clamp feedback"}
             }
           ] = startup.body
  end

  test "rejects sequences that reference unknown public skills" do
    module = unique_module(:invalid_skill_sequence)

    output =
      capture_io(:stderr, fn ->
        Code.compile_quoted(
          quote do
            defmodule unquote(module) do
              use Ogol.Sequence

              sequence do
                name(:invalid_skill)
                topology(Ogol.TestSupport.SequenceTopology)
                do_skill(:clamp, :unknown_skill)
              end
            end
          end
        )
      end)

    assert output =~ "does not expose public skill :unknown_skill"
  end

  test "rejects signal refs in durable waits" do
    module = unique_module(:invalid_signal_wait_sequence)

    output =
      capture_io(:stderr, fn ->
        Code.compile_quoted(
          quote do
            defmodule unquote(module) do
              use Ogol.Sequence

              sequence do
                name(:invalid_signal_wait)
                topology(Ogol.TestSupport.SequenceTopology)
                wait(Ref.signal(:robot, :picked))
              end
            end
          end
        )
      end)

    assert output =~ "cannot be used as durable boolean state"
  end

  test "rejects unknown procedures in run statements" do
    module = unique_module(:invalid_run_sequence)

    output =
      capture_io(:stderr, fn ->
        Code.compile_quoted(
          quote do
            defmodule unquote(module) do
              use Ogol.Sequence

              sequence do
                name(:invalid_run)
                topology(Ogol.TestSupport.SequenceTopology)
                run(:missing_proc)
              end
            end
          end
        )
      end)

    assert output =~ "run references unknown procedure :missing_proc"
  end
end
