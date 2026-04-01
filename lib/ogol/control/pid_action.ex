defmodule Ogol.Control.PIDAction do
  @moduledoc """
  Machine `foreign` action wrapper around `Ogol.Control.PID`.

  Supported actions:

  - `:reset`
  - `:step`
  """

  @behaviour Ogol.ForeignAction

  alias Ogol.Control.PID
  alias Ogol.Control.PID.Config
  alias Ogol.Control.PID.Memory
  alias Ogol.Runtime.Staging

  @default_interval_ms 100
  @default_tick :control_tick
  @default_disable_mode :reset
  @default_invalid_input :error

  @type options :: %{
          config: Config.t(),
          measurement_fact: atom(),
          setpoint_fact: atom(),
          enable_fact: atom() | nil,
          output: atom(),
          tick: atom(),
          interval_ms: pos_integer(),
          disable_mode: :freeze | :reset,
          invalid_input: :error | :hold_last,
          reset_output: number() | nil,
          integral_field: atom(),
          previous_error_field: atom(),
          previous_timestamp_field: atom(),
          previous_measurement_field: atom(),
          last_output_field: atom()
        }

  @impl true
  def run(:reset, opts, _machine_module, _delivered, %Staging{} = staging) do
    with {:ok, options} <- normalize_options(opts, false) do
      {:ok, reset_staging(staging, options)}
    end
  end

  def run(:step, opts, _machine_module, _delivered, %Staging{} = staging) do
    with {:ok, options} <- normalize_options(opts, true),
         {:ok, next_staging} <- step_staging(staging, options) do
      {:ok, next_staging}
    end
  end

  def run(kind, _opts, _machine_module, _delivered, _staging) do
    {:error, {:unsupported_pid_action, kind}}
  end

  defp step_staging(%Staging{} = staging, options) do
    cond do
      not enabled?(staging.data.facts, options.enable_fact) ->
        {:ok, disabled_staging(staging, options)}

      true ->
        execute_pid_step(staging, options)
    end
  end

  defp execute_pid_step(%Staging{} = staging, options) do
    with {:ok, measurement} <- fetch_numeric_fact(staging, options.measurement_fact),
         {:ok, setpoint} <- fetch_numeric_fact(staging, options.setpoint_fact),
         {:ok, result} <-
           PID.step(
             options.config,
             measurement,
             setpoint,
             memory_from_fields(staging, options),
             System.monotonic_time(:millisecond)
           ) do
      next_staging =
        staging
        |> put_memory(result.memory, options)
        |> put_output(result.output, options.output)
        |> schedule_next_tick(options)

      {:ok, next_staging}
    else
      {:error, {:missing_fact, _fact} = reason} ->
        handle_invalid_input(staging, options, reason)

      {:error, {:invalid_fact, _fact, _value} = reason} ->
        handle_invalid_input(staging, options, reason)

      {:error, reason} ->
        {:error, {:pid_step_failed, reason}}
    end
  end

  defp handle_invalid_input(%Staging{} = staging, %{invalid_input: :hold_last} = options, _reason) do
    hold_output = current_output(staging, options)

    {:ok,
     staging
     |> put_output(hold_output, options.output)
     |> schedule_next_tick(options)}
  end

  defp handle_invalid_input(%Staging{}, _options, reason),
    do: {:error, {:pid_invalid_input, reason}}

  defp disabled_staging(%Staging{} = staging, %{disable_mode: :freeze} = options) do
    schedule_next_tick(staging, options)
  end

  defp disabled_staging(%Staging{} = staging, %{disable_mode: :reset} = options) do
    staging
    |> reset_staging(options)
    |> schedule_next_tick(options)
  end

  defp reset_staging(%Staging{} = staging, options) do
    reset_output = reset_output(staging, options)
    memory = PID.reset_memory(reset_output)

    next_staging =
      staging
      |> put_memory(memory, options)

    if is_number(options.reset_output) do
      put_output(next_staging, reset_output, options.output)
    else
      next_staging
    end
  end

  defp put_memory(%Staging{} = staging, %Memory{} = memory, options) do
    next_fields =
      staging.data.fields
      |> Map.put(options.integral_field, memory.integral)
      |> Map.put(options.previous_error_field, memory.previous_error)
      |> Map.put(options.previous_timestamp_field, memory.previous_timestamp)
      |> Map.put(options.previous_measurement_field, memory.previous_measurement)
      |> Map.put(options.last_output_field, memory.last_output)

    %{staging | data: %{staging.data | fields: next_fields}}
  end

  defp put_output(%Staging{} = staging, output_value, output_name) do
    next_outputs = Map.put(staging.data.outputs, output_name, output_value)

    %{
      staging
      | data: %{staging.data | outputs: next_outputs},
        boundary_effects:
          staging.boundary_effects ++ [{:output, %{name: output_name, value: output_value}}]
    }
  end

  defp schedule_next_tick(%Staging{} = staging, options) do
    effect =
      {:state_timeout, %{name: options.tick, delay_ms: options.interval_ms, data: %{}, meta: %{}}}

    %{staging | boundary_effects: staging.boundary_effects ++ [effect]}
  end

  defp memory_from_fields(%Staging{} = staging, options) do
    fields = staging.data.fields

    Memory.new!(%{
      integral: Map.get(fields, options.integral_field, 0.0),
      previous_error: Map.get(fields, options.previous_error_field, 0.0),
      previous_timestamp: Map.get(fields, options.previous_timestamp_field),
      previous_measurement: Map.get(fields, options.previous_measurement_field),
      last_output: Map.get(fields, options.last_output_field, 0.0)
    })
  end

  defp current_output(%Staging{} = staging, options) do
    Map.get(
      staging.data.outputs,
      options.output,
      Map.get(staging.data.fields, options.last_output_field, 0.0)
    )
  end

  defp reset_output(%Staging{} = staging, %{reset_output: nil} = options),
    do: current_output(staging, options)

  defp reset_output(_staging, %{reset_output: value}), do: value * 1.0

  defp fetch_numeric_fact(%Staging{} = staging, fact_name) do
    case Map.fetch(staging.data.facts, fact_name) do
      {:ok, value} when is_number(value) -> {:ok, value * 1.0}
      {:ok, value} -> {:error, {:invalid_fact, fact_name, value}}
      :error -> {:error, {:missing_fact, fact_name}}
    end
  end

  defp enabled?(_facts, nil), do: true
  defp enabled?(facts, fact_name), do: Map.get(facts, fact_name, false) == true

  defp normalize_options(opts, require_config?) when is_list(opts) do
    with {:ok, config} <- maybe_normalize_config(opts, require_config?),
         {:ok, measurement_fact} <- fetch_atom_option(opts, :measurement_fact),
         {:ok, setpoint_fact} <- fetch_atom_option(opts, :setpoint_fact),
         {:ok, output} <- fetch_atom_option(opts, :output),
         {:ok, tick} <- fetch_atom_option(opts, :tick, @default_tick),
         {:ok, interval_ms} <-
           fetch_positive_integer_option(opts, :interval_ms, @default_interval_ms),
         {:ok, disable_mode} <-
           fetch_mode_option(opts, :disable_mode, [:freeze, :reset], @default_disable_mode),
         {:ok, invalid_input} <-
           fetch_mode_option(opts, :invalid_input, [:error, :hold_last], @default_invalid_input),
         {:ok, enable_fact} <- fetch_optional_atom_option(opts, :enable_fact),
         {:ok, integral_field} <- fetch_atom_option(opts, :integral_field, :integral),
         {:ok, previous_error_field} <-
           fetch_atom_option(opts, :previous_error_field, :previous_error),
         {:ok, previous_timestamp_field} <-
           fetch_atom_option(opts, :previous_timestamp_field, :previous_timestamp),
         {:ok, previous_measurement_field} <-
           fetch_atom_option(opts, :previous_measurement_field, :previous_measurement),
         {:ok, last_output_field} <- fetch_atom_option(opts, :last_output_field, :last_output),
         {:ok, reset_output} <- fetch_optional_number_option(opts, :reset_output) do
      {:ok,
       %{
         config: config,
         measurement_fact: measurement_fact,
         setpoint_fact: setpoint_fact,
         enable_fact: enable_fact,
         output: output,
         tick: tick,
         interval_ms: interval_ms,
         disable_mode: disable_mode,
         invalid_input: invalid_input,
         reset_output: reset_output,
         integral_field: integral_field,
         previous_error_field: previous_error_field,
         previous_timestamp_field: previous_timestamp_field,
         previous_measurement_field: previous_measurement_field,
         last_output_field: last_output_field
       }}
    end
  end

  defp normalize_options(other, _require_config?), do: {:error, {:invalid_pid_options, other}}

  defp maybe_normalize_config(opts, true), do: normalize_config(Keyword.get(opts, :config, %{}))
  defp maybe_normalize_config(_opts, false), do: {:ok, nil}

  defp normalize_config(%Config{} = config), do: {:ok, config}
  defp normalize_config(config) when is_list(config), do: normalize_config(Map.new(config))

  defp normalize_config(config) when is_map(config) do
    case Config.new(config) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:invalid_pid_config, reason}}
    end
  end

  defp normalize_config(other), do: {:error, {:invalid_pid_config, other}}

  defp fetch_atom_option(opts, key, default \\ :__missing__)

  defp fetch_atom_option(opts, key, default) when is_atom(default) and default != :__missing__ do
    case Keyword.get(opts, key, default) do
      value when is_atom(value) -> {:ok, value}
      value -> {:error, {:invalid_pid_option, key, value}}
    end
  end

  defp fetch_atom_option(opts, key, :__missing__) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_pid_option, key, value}}
      :error -> {:error, {:missing_pid_option, key}}
    end
  end

  defp fetch_optional_atom_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_atom(value) -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:error, {:invalid_pid_option, key, value}}
      :error -> {:ok, nil}
    end
  end

  defp fetch_positive_integer_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value -> {:error, {:invalid_pid_option, key, value}}
    end
  end

  defp fetch_mode_option(opts, key, allowed, default) do
    case Keyword.get(opts, key, default) do
      value ->
        if value in allowed do
          {:ok, value}
        else
          {:error, {:invalid_pid_option, key, value}}
        end
    end
  end

  defp fetch_optional_number_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) -> {:ok, value * 1.0}
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:error, {:invalid_pid_option, key, value}}
      :error -> {:ok, nil}
    end
  end
end
