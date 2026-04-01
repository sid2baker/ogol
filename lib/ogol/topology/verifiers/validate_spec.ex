defmodule Ogol.Topology.Verifiers.ValidateSpec do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    machines = Spark.Dsl.Verifier.get_entities(dsl_state, [:machines])

    with :ok <- ensure_machines_exist(dsl_state, machines),
         :ok <- ensure_unique_machine_modules(dsl_state, machines),
         :ok <- ensure_machine_modules_export_interface(dsl_state, machines) do
      :ok
    end
  end

  defp ensure_machines_exist(dsl_state, []) do
    {:error, dsl_error(dsl_state, "topology must declare at least one machine")}
  end

  defp ensure_machines_exist(_dsl_state, _machines), do: :ok

  defp ensure_unique_machine_modules(_dsl_state, []), do: :ok

  defp ensure_unique_machine_modules(dsl_state, machines) do
    case duplicate_machine_module(machines) do
      nil ->
        :ok

      %{module: module} = machine ->
        {:error,
         dsl_error(
           dsl_state,
           "machine module #{inspect(module)} may only appear once in a topology",
           machine
         )}
    end
  end

  defp ensure_machine_modules_export_interface(dsl_state, machines) do
    Enum.reduce_while(machines, :ok, fn machine, :ok ->
      cond do
        not Code.ensure_loaded?(machine.module) ->
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "machine #{inspect(machine.name)} references unloaded module #{inspect(machine.module)}",
              machine
            )}}

        function_exported?(machine.module, :__ogol_topology__, 0) ->
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "machine #{inspect(machine.name)} references topology module #{inspect(machine.module)}; nested topologies are not supported",
              machine
            )}}

        not function_exported?(machine.module, :__ogol_machine__, 0) ->
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "machine #{inspect(machine.name)} module #{inspect(machine.module)} does not expose Ogol machine metadata",
              machine
            )}}

        not function_exported?(machine.module, :__ogol_interface__, 0) ->
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "machine #{inspect(machine.name)} module #{inspect(machine.module)} does not expose Ogol interface metadata",
              machine
            )}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp dsl_error(dsl_state, message, entity \\ nil) do
    DslError.exception(
      message: message,
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      path: Spark.Dsl.Verifier.get_persisted(dsl_state, :path),
      entity: entity
    )
  end

  defp duplicate_machine_module(machines) do
    machines
    |> Enum.group_by(& &1.module)
    |> Enum.find_value(fn
      {_module, [_single]} -> nil
      {_module, [duplicate | _rest]} -> duplicate
    end)
  end
end
