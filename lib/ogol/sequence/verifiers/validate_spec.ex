defmodule Ogol.Sequence.Verifiers.ValidateSpec do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Ogol.Sequence.Dsl
  alias Ogol.Sequence.Model
  alias Spark.Error.DslError

  @global_topology_items MapSet.new([:estop])
  @step_modules [Dsl.DoSkill, Dsl.Wait, Dsl.Run, Dsl.Repeat, Dsl.Fail]

  @impl true
  def verify(dsl_state) do
    topology = Spark.Dsl.Verifier.get_option(dsl_state, [:sequence], :topology)
    items = Spark.Dsl.Verifier.get_entities(dsl_state, [:sequence])
    procedures = Enum.filter(items, &match?(%Dsl.Proc{}, &1))
    steps = Enum.filter(items, &step?/1)
    machines_by_name = machines_by_name(topology)
    procedure_names = MapSet.new(Enum.map(procedures, & &1.name))

    with :ok <- ensure_topology_exports_metadata(dsl_state, topology),
         :ok <- validate_invariants(dsl_state, items, machines_by_name),
         :ok <- validate_procedures(dsl_state, procedures, procedure_names, machines_by_name),
         :ok <- validate_steps(dsl_state, steps, procedure_names, machines_by_name) do
      :ok
    end
  end

  defp ensure_topology_exports_metadata(dsl_state, topology) do
    cond do
      not Code.ensure_loaded?(topology) ->
        {:error,
         dsl_error(
           dsl_state,
           "sequence references unloaded topology module #{inspect(topology)}"
         )}

      not function_exported?(topology, :__ogol_topology__, 0) ->
        {:error,
         dsl_error(
           dsl_state,
           "sequence topology #{inspect(topology)} does not expose Ogol topology metadata"
         )}

      true ->
        :ok
    end
  end

  defp validate_invariants(dsl_state, items, machines_by_name) do
    items
    |> Enum.filter(&match?(%Dsl.Invariant{}, &1))
    |> Enum.reduce_while(:ok, fn invariant, :ok ->
      case validate_boolean_expr(dsl_state, invariant.condition, machines_by_name, invariant) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_procedures(dsl_state, procedures, procedure_names, machines_by_name) do
    Enum.reduce_while(procedures, :ok, fn proc, :ok ->
      validate_steps(dsl_state, proc.body || [], procedure_names, machines_by_name, proc)
      |> case do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_steps(dsl_state, steps, procedure_names, machines_by_name, parent \\ nil) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case validate_step(dsl_state, step, procedure_names, machines_by_name, parent) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_step(
         dsl_state,
         %Dsl.DoSkill{} = step,
         _procedure_names,
         machines_by_name,
         _parent
       ) do
    with :ok <- ensure_machine_skill(dsl_state, step.machine, step.skill, machines_by_name, step),
         :ok <- validate_optional_guard(dsl_state, step.when, machines_by_name, step) do
      :ok
    end
  end

  defp validate_step(dsl_state, %Dsl.Wait{} = step, _procedure_names, machines_by_name, _parent) do
    with :ok <- validate_optional_guard(dsl_state, step.when, machines_by_name, step),
         :ok <- validate_wait_condition(dsl_state, step, machines_by_name) do
      :ok
    end
  end

  defp validate_step(dsl_state, %Dsl.Run{} = step, procedure_names, machines_by_name, _parent) do
    with :ok <- validate_optional_guard(dsl_state, step.when, machines_by_name, step),
         :ok <- ensure_procedure_exists(dsl_state, step.procedure, procedure_names, step) do
      :ok
    end
  end

  defp validate_step(dsl_state, %Dsl.Repeat{} = step, procedure_names, machines_by_name, _parent) do
    with :ok <- validate_optional_guard(dsl_state, step.when, machines_by_name, step),
         :ok <-
           validate_steps(dsl_state, step.body || [], procedure_names, machines_by_name, step) do
      :ok
    end
  end

  defp validate_step(_dsl_state, %Dsl.Fail{}, _procedure_names, _machines_by_name, _parent),
    do: :ok

  defp validate_wait_condition(
         dsl_state,
         %Dsl.Wait{signal?: true, condition: condition} = step,
         machines_by_name
       ) do
    case condition do
      %Model.SignalRef{} = ref ->
        ensure_signal_ref(dsl_state, ref, machines_by_name, step)

      other ->
        {:error,
         dsl_error(
           dsl_state,
           "signal wait requires a SignalRef, got #{inspect(other)}",
           step
         )}
    end
  end

  defp validate_wait_condition(
         dsl_state,
         %Dsl.Wait{condition: condition} = step,
         machines_by_name
       ) do
    validate_boolean_expr(dsl_state, condition, machines_by_name, step)
  end

  defp validate_boolean_expr(_dsl_state, value, _machines_by_name, _entity)
       when is_boolean(value),
       do: :ok

  defp validate_boolean_expr(dsl_state, %Model.StatusRef{} = ref, machines_by_name, entity) do
    ensure_status_ref(dsl_state, ref, machines_by_name, entity)
  end

  defp validate_boolean_expr(
         dsl_state,
         %Model.TopologyRef{scope: :system, item: item},
         _machines,
         entity
       ) do
    if MapSet.member?(@global_topology_items, item) do
      :ok
    else
      {:error,
       dsl_error(
         dsl_state,
         "unknown topology-visible item #{inspect(item)}",
         entity
       )}
    end
  end

  defp validate_boolean_expr(dsl_state, %Model.Expr.Not{expr: expr}, machines_by_name, entity) do
    validate_boolean_expr(dsl_state, expr, machines_by_name, entity)
  end

  defp validate_boolean_expr(
         dsl_state,
         %Model.Expr.And{left: left, right: right},
         machines_by_name,
         entity
       ) do
    with :ok <- validate_boolean_expr(dsl_state, left, machines_by_name, entity),
         :ok <- validate_boolean_expr(dsl_state, right, machines_by_name, entity) do
      :ok
    end
  end

  defp validate_boolean_expr(
         dsl_state,
         %Model.Expr.Or{left: left, right: right},
         machines_by_name,
         entity
       ) do
    with :ok <- validate_boolean_expr(dsl_state, left, machines_by_name, entity),
         :ok <- validate_boolean_expr(dsl_state, right, machines_by_name, entity) do
      :ok
    end
  end

  defp validate_boolean_expr(dsl_state, %Model.Expr.Compare{} = expr, machines_by_name, entity) do
    with :ok <- validate_value_expr(dsl_state, expr.left, machines_by_name, entity),
         :ok <- validate_value_expr(dsl_state, expr.right, machines_by_name, entity) do
      :ok
    end
  end

  defp validate_boolean_expr(dsl_state, %Model.SignalRef{} = ref, machines_by_name, entity) do
    with :ok <- ensure_signal_ref(dsl_state, ref, machines_by_name, entity) do
      {:error,
       dsl_error(
         dsl_state,
         "signal reference #{inspect(ref.item)} cannot be used as durable boolean state without an explicit signal wait",
         entity
       )}
    end
  end

  defp validate_boolean_expr(dsl_state, other, _machines_by_name, entity) do
    {:error, dsl_error(dsl_state, "invalid boolean expression #{inspect(other)}", entity)}
  end

  defp validate_value_expr(_dsl_state, value, _machines_by_name, _entity)
       when is_boolean(value) or is_integer(value) or is_float(value) or is_binary(value),
       do: :ok

  defp validate_value_expr(dsl_state, %Model.StatusRef{} = ref, machines_by_name, entity) do
    ensure_status_ref(dsl_state, ref, machines_by_name, entity)
  end

  defp validate_value_expr(dsl_state, %Model.TopologyRef{} = ref, machines_by_name, entity) do
    validate_boolean_expr(dsl_state, ref, machines_by_name, entity)
  end

  defp validate_value_expr(dsl_state, other, _machines_by_name, entity) do
    {:error, dsl_error(dsl_state, "invalid value expression #{inspect(other)}", entity)}
  end

  defp validate_optional_guard(_dsl_state, nil, _machines_by_name, _entity), do: :ok

  defp validate_optional_guard(dsl_state, guard, machines_by_name, entity) do
    validate_boolean_expr(dsl_state, guard, machines_by_name, entity)
  end

  defp ensure_procedure_exists(dsl_state, procedure, procedure_names, entity) do
    if MapSet.member?(procedure_names, procedure) do
      :ok
    else
      {:error,
       dsl_error(dsl_state, "run references unknown procedure #{inspect(procedure)}", entity)}
    end
  end

  defp ensure_machine_skill(dsl_state, machine_name, skill, machines_by_name, entity) do
    with {:ok, module} <- fetch_machine_module(dsl_state, machine_name, machines_by_name, entity),
         true <- MapSet.member?(interface_skill_names(module), skill) do
      :ok
    else
      false ->
        {:error,
         dsl_error(
           dsl_state,
           "machine #{inspect(machine_name)} does not expose public skill #{inspect(skill)}",
           entity
         )}

      {:error, _} = error ->
        error
    end
  end

  defp ensure_status_ref(dsl_state, %Model.StatusRef{} = ref, machines_by_name, entity) do
    with {:ok, module} <- fetch_machine_module(dsl_state, ref.machine, machines_by_name, entity),
         true <- MapSet.member?(interface_status_names(module), ref.item) do
      :ok
    else
      false ->
        {:error,
         dsl_error(
           dsl_state,
           "machine #{inspect(ref.machine)} does not expose public status #{inspect(ref.item)}",
           entity
         )}

      {:error, _} = error ->
        error
    end
  end

  defp ensure_signal_ref(dsl_state, %Model.SignalRef{} = ref, machines_by_name, entity) do
    with {:ok, module} <- fetch_machine_module(dsl_state, ref.machine, machines_by_name, entity),
         true <- MapSet.member?(interface_signal_names(module), ref.item) do
      :ok
    else
      false ->
        {:error,
         dsl_error(
           dsl_state,
           "machine #{inspect(ref.machine)} does not expose public signal #{inspect(ref.item)}",
           entity
         )}

      {:error, _} = error ->
        error
    end
  end

  defp fetch_machine_module(dsl_state, machine_name, machines_by_name, entity) do
    case Map.fetch(machines_by_name, machine_name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, dsl_error(dsl_state, "unknown machine #{inspect(machine_name)}", entity)}
    end
  end

  defp machines_by_name(topology) do
    topology.__ogol_topology__().machines
    |> Map.new(&{&1.name, &1.module})
  end

  defp interface_skill_names(module) do
    module.__ogol_contract__().skills
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp interface_signal_names(module) do
    module.__ogol_contract__().signals
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp interface_status_names(module) do
    contract = module.__ogol_contract__()

    (contract.facts ++ contract.outputs ++ contract.fields)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp step?(item) do
    Enum.any?(@step_modules, fn mod -> match?(%{__struct__: ^mod}, item) end)
  end

  defp dsl_error(dsl_state, message, entity \\ nil) do
    DslError.exception(
      message: message,
      path: [:sequence],
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      location: if(entity, do: Spark.Dsl.Entity.anno(entity))
    )
  end
end
