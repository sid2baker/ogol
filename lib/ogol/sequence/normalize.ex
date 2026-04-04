defmodule Ogol.Sequence.Normalize do
  @moduledoc false

  alias Ogol.Sequence.Dsl
  alias Ogol.Sequence.Model
  alias Spark.Dsl.Verifier

  @step_modules [Dsl.DoSkill, Dsl.Wait, Dsl.Run, Dsl.Delay, Dsl.Repeat, Dsl.Fail]

  @spec from_dsl!(map(), module()) :: Model.t()
  def from_dsl!(dsl_state, module) do
    name = Verifier.get_option(dsl_state, [:sequence], :name)
    topology = Verifier.get_option(dsl_state, [:sequence], :topology)
    meaning = Verifier.get_option(dsl_state, [:sequence], :meaning)
    items = Verifier.get_entities(dsl_state, [:sequence])

    invariants =
      items
      |> Enum.filter(&match?(%Dsl.Invariant{}, &1))
      |> Enum.with_index(1)
      |> Enum.map(fn {invariant, index} ->
        %Model.Invariant{
          id: "#{name}.invariant.#{index}",
          condition: invariant.condition,
          meaning: invariant.meaning
        }
      end)

    procedures =
      items
      |> Enum.filter(&match?(%Dsl.Proc{}, &1))
      |> Enum.map(fn proc ->
        %Model.ProcedureDefinition{
          id: "#{name}.#{proc.name}",
          name: proc.name,
          meaning: proc.meaning,
          body: normalize_steps(name, proc.name, proc.body || [])
        }
      end)

    root_steps =
      items
      |> Enum.filter(&step?/1)
      |> then(&normalize_steps(name, :root, &1))

    %Model{
      module: module,
      sequence: %Model.SequenceDefinition{
        id: to_string(name),
        name: name,
        topology: topology,
        meaning: meaning,
        root: root_steps,
        invariants: invariants,
        procedures: procedures
      }
    }
  end

  defp step?(item) do
    Enum.any?(@step_modules, fn mod -> match?(%{__struct__: ^mod}, item) end)
  end

  defp normalize_steps(sequence_name, scope_name, items) do
    items
    |> Enum.with_index(1)
    |> Enum.map(fn {step, index} -> normalize_step(sequence_name, scope_name, index, step) end)
  end

  defp normalize_step(sequence_name, scope_name, index, %Dsl.DoSkill{} = step) do
    %Model.Step{
      id: step_id(sequence_name, scope_name, index, :do_skill),
      kind: :do_skill,
      target: %Model.SkillRef{machine: step.machine, skill: step.skill},
      guard: step.when,
      timeout: maybe_timeout(:request, step.timeout),
      projection: projection(step.meaning, "Invoke #{step.machine}.#{step.skill}")
    }
  end

  defp normalize_step(sequence_name, scope_name, index, %Dsl.Wait{} = step) do
    kind = if step.signal?, do: :wait_signal, else: :wait_status

    %Model.Step{
      id: step_id(sequence_name, scope_name, index, kind),
      kind: kind,
      condition: step.condition,
      guard: step.when,
      timeout: maybe_timeout(:effect, step.timeout),
      on_timeout: maybe_failure(step.fail),
      projection: projection(step.meaning, "Wait for condition")
    }
  end

  defp normalize_step(sequence_name, scope_name, index, %Dsl.Run{} = step) do
    %Model.Step{
      id: step_id(sequence_name, scope_name, index, :run),
      kind: :run_procedure,
      procedure: "#{sequence_name}.#{step.procedure}",
      guard: step.when,
      projection: projection(step.meaning, "Run #{step.procedure}")
    }
  end

  defp normalize_step(sequence_name, scope_name, index, %Dsl.Delay{} = step) do
    %Model.Step{
      id: step_id(sequence_name, scope_name, index, :delay),
      kind: :delay,
      duration_ms: step.duration_ms,
      projection: projection(step.meaning, "Delay #{step.duration_ms} ms")
    }
  end

  defp normalize_step(sequence_name, scope_name, index, %Dsl.Repeat{} = step) do
    %Model.Step{
      id: step_id(sequence_name, scope_name, index, :repeat),
      kind: :repeat,
      guard: step.when,
      body: normalize_steps(sequence_name, "#{scope_name}.repeat#{index}", step.body || []),
      projection: projection(step.meaning, "Repeat block")
    }
  end

  defp normalize_step(sequence_name, scope_name, index, %Dsl.Fail{} = step) do
    %Model.Step{
      id: step_id(sequence_name, scope_name, index, :fail),
      kind: :fail,
      message: step.message,
      projection: projection(step.meaning, step.message || "Fail")
    }
  end

  defp step_id(sequence_name, scope_name, index, kind) do
    "#{sequence_name}.#{scope_name}.step#{index}.#{kind}"
  end

  defp maybe_timeout(_kind, nil), do: nil

  defp maybe_timeout(kind, duration_ms) do
    %Model.TimeoutSpec{kind: kind, duration_ms: duration_ms}
  end

  defp maybe_failure(nil), do: nil
  defp maybe_failure(message), do: %Model.Failure{kind: :fail, message: message}

  defp projection(nil, fallback), do: %{label: fallback}
  defp projection(label, _fallback), do: %{label: label}
end
