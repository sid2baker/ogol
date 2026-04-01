defmodule Ogol.Control.PID do
  @moduledoc """
  Reusable PID controller math for machine-local control loops.

  The controller math is intentionally kept outside the machine DSL so it can be
  tested directly and reused through explicit `foreign` actions.
  """

  defmodule Config do
    @moduledoc false

    @anti_windup_modes [:none, :conditional, :clamp]
    @derivative_modes [:error, :measurement]

    @schema Zoi.struct(
              __MODULE__,
              %{
                kp: Zoi.number(),
                ki: Zoi.number() |> Zoi.default(0.0),
                kd: Zoi.number() |> Zoi.default(0.0),
                min_output: Zoi.number() |> Zoi.nullish() |> Zoi.default(nil),
                max_output: Zoi.number() |> Zoi.nullish() |> Zoi.default(nil),
                nominal_dt_ms: Zoi.integer() |> Zoi.gte(1) |> Zoi.default(100),
                anti_windup:
                  Zoi.atom()
                  |> Zoi.one_of(@anti_windup_modes, error: "unsupported anti-windup mode")
                  |> Zoi.default(:conditional),
                derivative_mode:
                  Zoi.atom()
                  |> Zoi.one_of(@derivative_modes, error: "unsupported derivative mode")
                  |> Zoi.default(:error)
              },
              coerce: true
            )
            |> Zoi.refine({__MODULE__, :validate_bounds, []})

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @spec schema() :: Zoi.schema()
    def schema, do: @schema

    @spec new(map()) :: {:ok, t()} | {:error, term()}
    def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

    @spec new!(map()) :: t()
    def new!(attrs) do
      case new(attrs) do
        {:ok, value} -> value
        {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
      end
    end

    def validate_bounds(config, _opts \\ []) do
      if is_number(config.min_output) and is_number(config.max_output) and
           config.min_output > config.max_output do
        {:error, [Zoi.Error.custom_error(path: [:min_output], issue: {"min_output must be <= max_output", []})]}
      else
        :ok
      end
    end
  end

  defmodule Memory do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{
                integral: Zoi.number() |> Zoi.default(0.0),
                previous_error: Zoi.number() |> Zoi.default(0.0),
                previous_timestamp: Zoi.integer() |> Zoi.nullish() |> Zoi.default(nil),
                previous_measurement: Zoi.number() |> Zoi.nullish() |> Zoi.default(nil),
                last_output: Zoi.number() |> Zoi.default(0.0)
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @spec schema() :: Zoi.schema()
    def schema, do: @schema

    @spec new(map()) :: {:ok, t()} | {:error, term()}
    def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

    @spec new!(map()) :: t()
    def new!(attrs) do
      case new(attrs) do
        {:ok, value} -> value
        {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
      end
    end
  end

  defmodule Result do
    @moduledoc false

    @schema Zoi.struct(
              __MODULE__,
              %{
                output: Zoi.number(),
                error: Zoi.number(),
                dt_ms: Zoi.integer() |> Zoi.gte(1),
                proportional: Zoi.number(),
                integral: Zoi.number(),
                derivative: Zoi.number(),
                saturated?: Zoi.boolean(),
                memory: Memory.schema()
              },
              coerce: true
            )

    @type t :: unquote(Zoi.type_spec(@schema))

    @enforce_keys Zoi.Struct.enforce_keys(@schema)
    defstruct Zoi.Struct.struct_fields(@schema)

    @spec schema() :: Zoi.schema()
    def schema, do: @schema

    @spec new(map()) :: {:ok, t()} | {:error, term()}
    def new(attrs) when is_map(attrs), do: Zoi.parse(@schema, attrs)

    @spec new!(map()) :: t()
    def new!(attrs) do
      case new(attrs) do
        {:ok, value} -> value
        {:error, reason} -> raise ArgumentError, "Invalid #{inspect(__MODULE__)}: #{inspect(reason)}"
      end
    end
  end

  @type step_error ::
          {:invalid_config, term()}
          | {:invalid_memory, term()}
          | {:invalid_value, :measurement | :setpoint | :timestamp, term()}

  @spec step(Config.t() | map() | keyword(), number(), number(), Memory.t() | map(), integer()) ::
          {:ok, Result.t()} | {:error, step_error()}
  def step(config, measurement, setpoint, memory, now_ms) do
    with {:ok, %Config{} = config} <- normalize_config(config),
         {:ok, %Memory{} = memory} <- normalize_memory(memory),
         {:ok, measurement} <- normalize_number(:measurement, measurement),
         {:ok, setpoint} <- normalize_number(:setpoint, setpoint),
         {:ok, now_ms} <- normalize_timestamp(now_ms) do
      dt_ms = effective_dt_ms(config, memory, now_ms)
      dt_s = dt_ms / 1_000.0
      error = setpoint - measurement
      proportional = config.kp * error
      derivative = derivative_term(config, memory, error, measurement, dt_s)
      integral = integral_term(config, memory, error, proportional, derivative, dt_s)
      unclamped_output = proportional + integral + derivative
      output = clamp(unclamped_output, config.min_output, config.max_output)

      result =
        Result.new!(%{
          output: output,
          error: error,
          dt_ms: dt_ms,
          proportional: proportional,
          integral: integral,
          derivative: derivative,
          saturated?: output != unclamped_output,
          memory:
            Memory.new!(%{
              integral: integral,
              previous_error: error,
              previous_timestamp: now_ms,
              previous_measurement: measurement,
              last_output: output
            })
        })

      {:ok, result}
    end
  end

  @spec reset_memory(number()) :: Memory.t()
  def reset_memory(last_output \\ 0.0) when is_number(last_output) do
    Memory.new!(%{
      integral: 0.0,
      previous_error: 0.0,
      previous_timestamp: nil,
      previous_measurement: nil,
      last_output: last_output
    })
  end

  defp normalize_config(%Config{} = config), do: {:ok, config}
  defp normalize_config(config) when is_list(config), do: normalize_config(Map.new(config))

  defp normalize_config(config) when is_map(config) do
    case Config.new(config) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:invalid_config, reason}}
    end
  end

  defp normalize_config(other), do: {:error, {:invalid_config, other}}

  defp normalize_memory(%Memory{} = memory), do: {:ok, memory}
  defp normalize_memory(memory) when is_list(memory), do: normalize_memory(Map.new(memory))

  defp normalize_memory(memory) when is_map(memory) do
    case Memory.new(memory) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:invalid_memory, reason}}
    end
  end

  defp normalize_memory(other), do: {:error, {:invalid_memory, other}}

  defp normalize_number(_field, value) when is_number(value), do: {:ok, value * 1.0}
  defp normalize_number(field, value), do: {:error, {:invalid_value, field, value}}

  defp normalize_timestamp(value) when is_integer(value), do: {:ok, value}
  defp normalize_timestamp(value), do: {:error, {:invalid_value, :timestamp, value}}

  defp effective_dt_ms(%Config{nominal_dt_ms: nominal_dt_ms}, %Memory{previous_timestamp: nil}, _now_ms),
    do: nominal_dt_ms

  defp effective_dt_ms(%Config{nominal_dt_ms: nominal_dt_ms}, %Memory{previous_timestamp: previous}, now_ms)
       when is_integer(previous) do
    delta = now_ms - previous
    if delta > 0, do: delta, else: nominal_dt_ms
  end

  defp derivative_term(%Config{kd: kd}, _memory, _error, _measurement, _dt_s)
       when kd == 0 or kd == 0.0,
       do: 0.0

  defp derivative_term(%Config{kd: kd, derivative_mode: :error}, %Memory{} = memory, error, _measurement, dt_s) do
    kd * ((error - memory.previous_error) / dt_s)
  end

  defp derivative_term(
         %Config{derivative_mode: :measurement},
         %Memory{previous_measurement: nil},
         _error,
         _measurement,
         _dt_s
       ),
       do: 0.0

  defp derivative_term(
         %Config{kd: kd, derivative_mode: :measurement},
         %Memory{previous_measurement: previous_measurement},
         _error,
         measurement,
         dt_s
       ) do
    kd * (-(measurement - previous_measurement) / dt_s)
  end

  defp integral_term(
         %Config{ki: ki},
         %Memory{} = memory,
         _error,
         _proportional,
         _derivative,
         _dt_s
       )
       when ki == 0 or ki == 0.0,
       do: memory.integral

  defp integral_term(%Config{} = config, %Memory{} = memory, error, proportional, derivative, dt_s) do
    candidate = memory.integral + config.ki * error * dt_s

    case config.anti_windup do
      :none ->
        candidate

      :conditional ->
        saturated_output = clamp(proportional + candidate + derivative, config.min_output, config.max_output)

        cond do
          saturated_output == config.max_output and error > 0 -> memory.integral
          saturated_output == config.min_output and error < 0 -> memory.integral
          true -> candidate
        end

      :clamp ->
        lower =
          case config.min_output do
            nil -> nil
            min_output -> min_output - proportional - derivative
          end

        upper =
          case config.max_output do
            nil -> nil
            max_output -> max_output - proportional - derivative
          end

        clamp(candidate, lower, upper)
    end
  end

  defp clamp(value, nil, nil), do: value
  defp clamp(value, min, nil) when is_number(min), do: max(value, min)
  defp clamp(value, nil, max) when is_number(max), do: min(value, max)
  defp clamp(value, min, max) when is_number(min) and is_number(max), do: value |> max(min) |> min(max)
end
