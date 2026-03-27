defmodule Ogol.Topology.Verifiers.ValidateSpec do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Ogol.Machine.Info
  alias Ogol.Topology.Dsl
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    root = Spark.Dsl.Verifier.get_option(dsl_state, [:topology], :root)
    machines = Spark.Dsl.Verifier.get_entities(dsl_state, [:machines])
    observations = Spark.Dsl.Verifier.get_entities(dsl_state, [:observations])
    machine_names = MapSet.new(Enum.map(machines, & &1.name))
    machines_by_name = Map.new(machines, &{&1.name, &1})

    with :ok <- ensure_machine_modules_export_interface(dsl_state, machines),
         :ok <- ensure_root_declared(dsl_state, root, machine_names),
         :ok <- ensure_dependency_targets_exist(dsl_state, machines, machines_by_name),
         :ok <- ensure_dependency_contracts(dsl_state, machines, machines_by_name),
         :ok <- ensure_invoke_contracts(dsl_state, machines, machines_by_name),
         :ok <- ensure_observation_sources_exist(dsl_state, observations, machine_names),
         :ok <-
           ensure_observation_sources_are_root_dependencies(
             dsl_state,
             machines_by_name,
             root,
             observations
           ),
         :ok <-
           ensure_observation_bindings_exist_on_root(
             dsl_state,
             machines_by_name,
             root,
             observations
           ),
         :ok <-
           ensure_observed_states_signals_and_status_exist(
             dsl_state,
             observations,
             machines_by_name,
             root
           ),
         :ok <- ensure_observation_uniqueness(dsl_state, observations) do
      :ok
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

  defp ensure_root_declared(dsl_state, root, machine_names) do
    if MapSet.member?(machine_names, root) do
      :ok
    else
      {:error,
       dsl_error(dsl_state, "topology root #{inspect(root)} must be declared in machines")}
    end
  end

  defp ensure_observation_sources_exist(dsl_state, observations, machine_names) do
    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      if MapSet.member?(machine_names, observation.source) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          dsl_error(
            dsl_state,
            "observation references unknown source machine #{inspect(observation.source)}",
            observation
          )}}
      end
    end)
  end

  defp ensure_dependency_targets_exist(dsl_state, machines, machines_by_name) do
    Enum.reduce_while(machines, :ok, fn machine, :ok ->
      machine.module
      |> machine_dependencies()
      |> Enum.reduce_while(:ok, fn dependency, :ok ->
        if Map.has_key?(machines_by_name, dependency.name) do
          {:cont, :ok}
        else
          {:halt,
           {:error,
            dsl_error(
              dsl_state,
              "machine #{inspect(machine.name)} declares dependency #{inspect(dependency.name)} but topology does not declare that machine",
              machine
            )}}
        end
      end)
      |> case do
        {:error, _} = error -> {:halt, error}
        :ok -> {:cont, :ok}
      end
    end)
  end

  defp ensure_dependency_contracts(dsl_state, machines, machines_by_name) do
    Enum.reduce_while(machines, :ok, fn machine, :ok ->
      machine.module
      |> machine_dependencies()
      |> Enum.reduce_while(:ok, fn dependency, :ok ->
        target_machine = Map.fetch!(machines_by_name, dependency.name)

        with :ok <-
               ensure_dependency_skills(dsl_state, machine, dependency, target_machine.module),
             :ok <-
               ensure_dependency_signals(dsl_state, machine, dependency, target_machine.module),
             :ok <-
               ensure_dependency_status(dsl_state, machine, dependency, target_machine.module) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:error, _} = error -> {:halt, error}
        :ok -> {:cont, :ok}
      end
    end)
  end

  defp ensure_invoke_contracts(dsl_state, machines, machines_by_name) do
    Enum.reduce_while(machines, :ok, fn machine, :ok ->
      dependency_map = Map.new(machine_dependencies(machine.module), &{&1.name, &1})

      machine.module
      |> invoke_actions()
      |> Enum.reduce_while(:ok, fn %{target: target, skill: skill}, :ok ->
        case {Map.get(dependency_map, target), Map.get(machines_by_name, target)} do
          {nil, _target_machine} ->
            {:cont, :ok}

          {_dependency, nil} ->
            {:halt,
             {:error,
              dsl_error(
                dsl_state,
                "machine #{inspect(machine.name)} invokes missing dependency #{inspect(target)}",
                machine
              )}}

          {dependency, target_machine} ->
            with :ok <-
                   ensure_target_exposes_invoked_skill(
                     dsl_state,
                     machine,
                     target,
                     skill,
                     target_machine.module
                   ),
                 :ok <-
                   ensure_dependency_declares_invoked_skill(
                     dsl_state,
                     machine,
                     dependency,
                     skill
                   ) do
              {:cont, :ok}
            else
              {:error, _} = error -> {:halt, error}
            end
        end
      end)
      |> case do
        {:error, _} = error -> {:halt, error}
        :ok -> {:cont, :ok}
      end
    end)
  end

  defp ensure_observation_sources_are_root_dependencies(
         dsl_state,
         machines_by_name,
         root,
         observations
       ) do
    root_machine = Map.fetch!(machines_by_name, root)

    dependency_names =
      root_machine.module
      |> machine_dependencies()
      |> Enum.map(& &1.name)
      |> MapSet.new()

    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      if MapSet.member?(dependency_names, observation.source) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          dsl_error(
            dsl_state,
            "observation source #{inspect(observation.source)} is not a declared dependency of root #{inspect(root)}",
            observation
          )}}
      end
    end)
  end

  defp ensure_observation_bindings_exist_on_root(dsl_state, machines_by_name, root, observations) do
    root_machine = Map.fetch!(machines_by_name, root)
    root_events = root_machine.module |> Info.events() |> Enum.map(& &1.name) |> MapSet.new()

    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      if MapSet.member?(root_events, observation.as) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          dsl_error(
            dsl_state,
            "observation binding #{inspect(observation.as)} must be declared as an event on root #{inspect(root)}",
            observation
          )}}
      end
    end)
  end

  defp ensure_observed_states_signals_and_status_exist(
         dsl_state,
         observations,
         machines_by_name,
         root
       ) do
    root_machine = Map.fetch!(machines_by_name, root)
    dependency_map = Map.new(machine_dependencies(root_machine.module), &{&1.name, &1})

    Enum.reduce_while(observations, :ok, fn observation, :ok ->
      machine = Map.fetch!(machines_by_name, observation.source)

      case observation do
        %Dsl.ObserveState{state: state} ->
          state_names = machine.module |> Info.states() |> Enum.map(& &1.name) |> MapSet.new()

          if MapSet.member?(state_names, state) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              dsl_error(
                dsl_state,
                "observation references unknown state #{inspect(state)} on #{inspect(observation.source)}",
                observation
              )}}
          end

        %Dsl.ObserveSignal{signal: signal} ->
          signal_names =
            machine.module.__ogol_interface__().signals
            |> Enum.map(& &1.name)
            |> MapSet.new()

          if MapSet.member?(signal_names, signal) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              dsl_error(
                dsl_state,
                "observation references unknown public signal #{inspect(signal)} on #{inspect(observation.source)}",
                observation
              )}}
          end

        %Dsl.ObserveStatus{item: item, source: source} ->
          dependency = Map.fetch!(dependency_map, source)
          status_names = interface_status_names(machine.module)

          cond do
            not MapSet.member?(status_names, item) ->
              {:halt,
               {:error,
                dsl_error(
                  dsl_state,
                  "observation references unknown public status item #{inspect(item)} on #{inspect(observation.source)}",
                  observation
                )}}

            dependency.status in [nil, []] ->
              {:halt,
               {:error,
                dsl_error(
                  dsl_state,
                  "observation references status item #{inspect(item)} on #{inspect(source)} but the root dependency does not declare any observed status items",
                  observation
                )}}

            item not in dependency.status ->
              {:halt,
               {:error,
                dsl_error(
                  dsl_state,
                  "observation references status item #{inspect(item)} on #{inspect(source)} outside the root dependency status contract",
                  observation
                )}}

            true ->
              {:cont, :ok}
          end

        %Dsl.ObserveDown{} ->
          {:cont, :ok}
      end
    end)
  end

  defp ensure_observation_uniqueness(dsl_state, observations) do
    with :ok <- ensure_unique_state_observations(dsl_state, observations),
         :ok <- ensure_unique_signal_observations(dsl_state, observations),
         :ok <- ensure_unique_status_observations(dsl_state, observations),
         :ok <- ensure_unique_down_observations(dsl_state, observations) do
      :ok
    end
  end

  defp ensure_unique_state_observations(dsl_state, observations) do
    ensure_unique_keys(dsl_state, observations, Dsl.ObserveState, fn obs ->
      {obs.source, obs.state}
    end)
  end

  defp ensure_unique_signal_observations(dsl_state, observations) do
    ensure_unique_keys(dsl_state, observations, Dsl.ObserveSignal, fn obs ->
      {obs.source, obs.signal}
    end)
  end

  defp ensure_unique_status_observations(dsl_state, observations) do
    ensure_unique_keys(dsl_state, observations, Dsl.ObserveStatus, fn obs ->
      {obs.source, obs.item}
    end)
  end

  defp ensure_unique_down_observations(dsl_state, observations) do
    ensure_unique_keys(dsl_state, observations, Dsl.ObserveDown, & &1.source)
  end

  defp ensure_unique_keys(dsl_state, observations, module, key_fun) do
    observations
    |> Enum.filter(&match?(%{__struct__: ^module}, &1))
    |> Enum.reduce_while(MapSet.new(), fn observation, seen ->
      key = key_fun.(observation)

      if MapSet.member?(seen, key) do
        {:halt,
         {:error,
          dsl_error(
            dsl_state,
            "duplicate #{module_label(module)} observation for #{inspect(key)}",
            observation
          )}}
      else
        {:cont, MapSet.put(seen, key)}
      end
    end)
    |> case do
      {:error, _} = error -> error
      _seen -> :ok
    end
  end

  defp module_label(Dsl.ObserveState), do: "state"
  defp module_label(Dsl.ObserveSignal), do: "signal"
  defp module_label(Dsl.ObserveStatus), do: "status"
  defp module_label(Dsl.ObserveDown), do: "down"

  defp machine_dependencies(module), do: Info.dependencies(module)

  defp interface_skill_names(module) do
    module.__ogol_interface__().skills
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp interface_signal_names(module) do
    module.__ogol_interface__().signals
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp interface_status_names(module) do
    status_spec = module.__ogol_interface__().status_spec

    (status_spec.facts ++ status_spec.outputs ++ status_spec.fields)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end

  defp ensure_dependency_skills(dsl_state, machine, dependency, target_module) do
    available_skills = interface_skill_names(target_module)

    Enum.reduce_while(dependency.skills || [], :ok, fn skill, :ok ->
      if MapSet.member?(available_skills, skill) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          dsl_error(
            dsl_state,
            "machine #{inspect(machine.name)} dependency #{inspect(dependency.name)} requires unknown skill #{inspect(skill)} on #{inspect(target_module)}",
            machine
          )}}
      end
    end)
  end

  defp ensure_dependency_signals(dsl_state, machine, dependency, target_module) do
    available_signals = interface_signal_names(target_module)

    Enum.reduce_while(dependency.signals || [], :ok, fn signal, :ok ->
      if MapSet.member?(available_signals, signal) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          dsl_error(
            dsl_state,
            "machine #{inspect(machine.name)} dependency #{inspect(dependency.name)} requires unknown public signal #{inspect(signal)} on #{inspect(target_module)}",
            machine
          )}}
      end
    end)
  end

  defp ensure_dependency_status(dsl_state, machine, dependency, target_module) do
    available_status = interface_status_names(target_module)

    Enum.reduce_while(dependency.status || [], :ok, fn item, :ok ->
      if MapSet.member?(available_status, item) do
        {:cont, :ok}
      else
        {:halt,
         {:error,
          dsl_error(
            dsl_state,
            "machine #{inspect(machine.name)} dependency #{inspect(dependency.name)} requires unknown public status item #{inspect(item)} on #{inspect(target_module)}",
            machine
          )}}
      end
    end)
  end

  defp ensure_target_exposes_invoked_skill(dsl_state, machine, target, skill, target_module) do
    if MapSet.member?(interface_skill_names(target_module), skill) do
      :ok
    else
      {:error,
       dsl_error(
         dsl_state,
         "machine #{inspect(machine.name)} invokes skill #{inspect(skill)} on dependency #{inspect(target)}, but #{inspect(target_module)} does not expose that skill",
         machine
       )}
    end
  end

  defp ensure_dependency_declares_invoked_skill(dsl_state, machine, dependency, skill) do
    declared_skills = dependency.skills || []

    if declared_skills == [] or skill in declared_skills do
      :ok
    else
      {:error,
       dsl_error(
         dsl_state,
         "machine #{inspect(machine.name)} invokes skill #{inspect(skill)} on dependency #{inspect(dependency.name)} outside its declared uses contract",
         machine
       )}
    end
  end

  defp invoke_actions(module) do
    machine = module.__ogol_machine__()

    state_entry_actions =
      machine.states
      |> Map.values()
      |> Enum.flat_map(& &1.entries)

    transition_actions =
      machine.transitions_by_source
      |> Map.values()
      |> List.flatten()
      |> Enum.flat_map(& &1.actions)

    (state_entry_actions ++ transition_actions)
    |> Enum.filter(&match?(%{kind: :invoke}, &1))
    |> Enum.map(& &1.args)
  end

  defp dsl_error(dsl_state, message, entity \\ nil) do
    DslError.exception(
      message: message,
      module: Spark.Dsl.Verifier.get_persisted(dsl_state, :module),
      path: Spark.Dsl.Verifier.get_persisted(dsl_state, :path),
      entity: entity
    )
  end
end
