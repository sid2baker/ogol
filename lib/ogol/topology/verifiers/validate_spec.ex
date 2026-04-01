defmodule Ogol.Topology.Verifiers.ValidateSpec do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Ogol.Machine.Info
  alias Ogol.Topology.Wiring
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    machines = Spark.Dsl.Verifier.get_entities(dsl_state, [:machines])

    with :ok <- ensure_machines_exist(dsl_state, machines),
         :ok <- ensure_machine_modules_export_interface(dsl_state, machines),
         :ok <- ensure_machine_wiring_valid(dsl_state, machines) do
      :ok
    end
  end

  defp ensure_machines_exist(dsl_state, []) do
    {:error, dsl_error(dsl_state, "topology must declare at least one machine")}
  end

  defp ensure_machines_exist(_dsl_state, _machines), do: :ok

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

        not function_exported?(machine.module, :__ogol_contract__, 0) ->
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "machine #{inspect(machine.name)} module #{inspect(machine.module)} does not expose Ogol contract metadata",
              machine
            )}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp ensure_machine_wiring_valid(_dsl_state, []), do: :ok

  defp ensure_machine_wiring_valid(dsl_state, machines) do
    Enum.reduce_while(machines, :ok, fn machine, :ok ->
      with {:ok, wiring} <- Wiring.normalize(machine.wiring),
           :ok <- validate_wiring_ports(machine.module, wiring, machine) do
        {:cont, :ok}
      else
        {:error, reason} ->
          {:halt, {:error, dsl_error(dsl_state, wiring_error_message(reason), machine)}}
      end
    end)
  end

  defp validate_wiring_ports(module, %Wiring{} = wiring, machine) do
    with :ok <- ensure_declared_ports(wiring.outputs, Info.outputs(module), :output, machine),
         :ok <- ensure_declared_ports(wiring.facts, Info.facts(module), :fact, machine),
         :ok <- ensure_declared_ports(wiring.commands, Info.commands(module), :command, machine) do
      :ok
    end
  end

  defp ensure_declared_ports(mapping, _declarations, _kind, _machine)
       when map_size(mapping) == 0 do
    :ok
  end

  defp ensure_declared_ports(mapping, declarations, kind, _machine) do
    declared_names =
      declarations
      |> Enum.map(& &1.name)
      |> MapSet.new()

    case Enum.find(Map.keys(mapping), &(not MapSet.member?(declared_names, &1))) do
      nil -> :ok
      name -> {:error, {:unknown_machine_port, kind, name}}
    end
  end

  defp wiring_error_message({:unknown_machine_port, kind, name}) do
    "machine wiring references unknown #{kind} #{inspect(name)}"
  end

  defp wiring_error_message({:invalid_topology_wiring_keys, unknown}) do
    "machine wiring uses unsupported keys #{inspect(unknown)}"
  end

  defp wiring_error_message({:invalid_topology_wiring_value, key, value}) do
    "machine wiring value for #{inspect(key)} is invalid: #{inspect(value)}"
  end

  defp wiring_error_message({:invalid_topology_wiring_mapping, value}) do
    "machine wiring mappings must use atom ports and atom endpoints: #{inspect(value)}"
  end

  defp wiring_error_message({:invalid_topology_command_binding, name, binding}) do
    "machine command wiring for #{inspect(name)} is invalid: #{inspect(binding)}"
  end

  defp wiring_error_message({:invalid_topology_command_args, args}) do
    "machine command wiring args are invalid: #{inspect(args)}"
  end

  defp wiring_error_message({:invalid_topology_wiring, wiring}) do
    "machine wiring is invalid: #{inspect(wiring)}"
  end

  defp wiring_error_message(reason), do: "machine wiring is invalid: #{inspect(reason)}"

  defp dsl_error(dsl_state, message, entity \\ nil) do
    DslError.exception(
      message: message,
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      path: Spark.Dsl.Verifier.get_persisted(dsl_state, :path),
      entity: entity
    )
  end
end
