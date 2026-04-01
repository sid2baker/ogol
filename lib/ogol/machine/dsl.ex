defmodule Ogol.Machine.Dsl do
  @moduledoc false

  defmodule MachineOptions do
    defstruct [
      :name,
      :meaning,
      :__spark_metadata__
    ]
  end

  defmodule Fact do
    defstruct [:name, :type, :default, :meaning, :public?, :__identifier__, :__spark_metadata__]
  end

  defmodule Event do
    defstruct [:name, :meaning, :skill?, :args, :__identifier__, :__spark_metadata__]
  end

  defmodule Request do
    defstruct [:name, :meaning, :skill?, :args, :__identifier__, :__spark_metadata__]
  end

  defmodule Command do
    defstruct [:name, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule Output do
    defstruct [:name, :type, :default, :meaning, :public?, :__identifier__, :__spark_metadata__]
  end

  defmodule Signal do
    defstruct [:name, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule Field do
    defstruct [:name, :type, :default, :meaning, :public?, :__identifier__, :__spark_metadata__]
  end

  defmodule SetFact do
    defstruct [:name, :value, :__spark_metadata__]
  end

  defmodule SetField do
    defstruct [:name, :value, :__spark_metadata__]
  end

  defmodule SetOutput do
    defstruct [:name, :value, :__spark_metadata__]
  end

  defmodule EmitSignal do
    defstruct [:name, :data, :meta, :__spark_metadata__]
  end

  defmodule EmitCommand do
    defstruct [:name, :data, :meta, :__spark_metadata__]
  end

  defmodule Reply do
    defstruct [:value, :__spark_metadata__]
  end

  defmodule Internal do
    defstruct [:name, :data, :meta, :__spark_metadata__]
  end

  defmodule StateTimeout do
    defstruct [:name, :delay_ms, :data, :meta, :__spark_metadata__]
  end

  defmodule CancelTimeout do
    defstruct [:name, :__spark_metadata__]
  end

  defmodule CallbackAction do
    defstruct [:name, :__spark_metadata__]
  end

  defmodule ForeignAction do
    defstruct [:kind, :module, :opts, :__spark_metadata__]
  end

  defmodule Stop do
    defstruct [:reason, :__spark_metadata__]
  end

  defmodule Hibernate do
    defstruct [:__spark_metadata__]
  end

  defmodule State do
    defstruct [
      :name,
      :initial?,
      :status,
      :meaning,
      :__identifier__,
      entries: [],
      __spark_metadata__: nil
    ]
  end

  defmodule Transition do
    defstruct [
      :source,
      :destination,
      :on,
      :guard,
      :priority,
      :reenter?,
      :meaning,
      actions: [],
      __spark_metadata__: nil
    ]
  end

  defmodule AlwaysSafety do
    defstruct [:check, :meaning, :__spark_metadata__]
  end

  defmodule WhileInSafety do
    defstruct [:state, :check, :meaning, :__spark_metadata__]
  end

  @skill_arg_base_types [:string, :integer, :float, :boolean]

  @machine %Spark.Dsl.Section{
    name: :machine,
    schema: [
      name: [type: :atom, doc: "Optional machine name override."],
      meaning: [type: :string, doc: "Human-readable machine meaning."]
    ]
  }

  @fact %Spark.Dsl.Entity{
    name: :fact,
    target: Fact,
    args: [:name, :type],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      type: [type: :atom, required: true],
      default: [type: :any],
      meaning: [type: :string],
      public?: [type: :boolean, default: false]
    ]
  }

  @event %Spark.Dsl.Entity{
    name: :event,
    target: Event,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      meaning: [type: :string],
      skill?: [type: :boolean, default: false],
      args: [type: {:custom, __MODULE__, :validate_skill_args, []}, default: []]
    ]
  }

  @request %Spark.Dsl.Entity{
    name: :request,
    target: Request,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      meaning: [type: :string],
      skill?: [type: :boolean, default: true],
      args: [type: {:custom, __MODULE__, :validate_skill_args, []}, default: []]
    ]
  }

  @command %Spark.Dsl.Entity{
    name: :command,
    target: Command,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      meaning: [type: :string]
    ]
  }

  @output %Spark.Dsl.Entity{
    name: :output,
    target: Output,
    args: [:name, :type],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      type: [type: :atom, required: true],
      default: [type: :any],
      meaning: [type: :string],
      public?: [type: :boolean, default: false]
    ]
  }

  @signal %Spark.Dsl.Entity{
    name: :signal,
    target: Signal,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      meaning: [type: :string]
    ]
  }

  @boundary %Spark.Dsl.Section{
    name: :boundary,
    entities: [@fact, @event, @request, @command, @output, @signal]
  }

  @field %Spark.Dsl.Entity{
    name: :field,
    target: Field,
    args: [:name, :type],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      type: [type: :atom, required: true],
      default: [type: :any],
      meaning: [type: :string],
      public?: [type: :boolean, default: false]
    ]
  }

  @memory %Spark.Dsl.Section{name: :memory, entities: [@field]}

  @set_fact %Spark.Dsl.Entity{
    name: :set_fact,
    target: SetFact,
    args: [:name, :value],
    schema: [
      name: [type: :atom, required: true],
      value: [type: :any, required: true]
    ]
  }

  @set_field %Spark.Dsl.Entity{
    name: :set_field,
    target: SetField,
    args: [:name, :value],
    schema: [
      name: [type: :atom, required: true],
      value: [type: :any, required: true]
    ]
  }

  @set_output %Spark.Dsl.Entity{
    name: :set_output,
    target: SetOutput,
    args: [:name, :value],
    schema: [
      name: [type: :atom, required: true],
      value: [type: :any, required: true]
    ]
  }

  @signal_action %Spark.Dsl.Entity{
    name: :signal,
    target: EmitSignal,
    args: [:name],
    schema: [
      name: [type: :atom, required: true],
      data: [type: :map, default: %{}],
      meta: [type: :map, default: %{}]
    ]
  }

  @command_action %Spark.Dsl.Entity{
    name: :command,
    target: EmitCommand,
    args: [:name],
    schema: [
      name: [type: :atom, required: true],
      data: [type: :map, default: %{}],
      meta: [type: :map, default: %{}]
    ]
  }

  @reply %Spark.Dsl.Entity{
    name: :reply,
    target: Reply,
    args: [:value],
    schema: [
      value: [type: :any, required: true]
    ]
  }

  @internal %Spark.Dsl.Entity{
    name: :internal,
    target: Internal,
    args: [:name],
    schema: [
      name: [type: :atom, required: true],
      data: [type: :map, default: %{}],
      meta: [type: :map, default: %{}]
    ]
  }

  @state_timeout %Spark.Dsl.Entity{
    name: :state_timeout,
    target: StateTimeout,
    args: [:name, :delay_ms],
    schema: [
      name: [type: :atom, required: true],
      delay_ms: [type: :non_neg_integer, required: true],
      data: [type: :map, default: %{}],
      meta: [type: :map, default: %{}]
    ]
  }

  @cancel_timeout %Spark.Dsl.Entity{
    name: :cancel_timeout,
    target: CancelTimeout,
    args: [:name],
    schema: [
      name: [type: :atom, required: true]
    ]
  }

  @callback_action %Spark.Dsl.Entity{
    name: :callback,
    target: CallbackAction,
    args: [:name],
    schema: [
      name: [type: :atom, required: true]
    ]
  }

  @foreign_action %Spark.Dsl.Entity{
    name: :foreign,
    target: ForeignAction,
    args: [:kind],
    schema: [
      kind: [type: :atom, required: true],
      module: [type: :atom, required: true],
      opts: [type: :keyword_list, default: []]
    ]
  }

  @stop %Spark.Dsl.Entity{
    name: :stop,
    target: Stop,
    args: [:reason],
    schema: [
      reason: [type: :any, required: true]
    ]
  }

  @hibernate %Spark.Dsl.Entity{
    name: :hibernate,
    target: Hibernate,
    args: [],
    schema: []
  }

  @state_entry_actions [
    @set_fact,
    @set_field,
    @set_output,
    @signal_action,
    @command_action,
    @reply,
    @internal,
    @state_timeout,
    @cancel_timeout,
    @callback_action,
    @foreign_action,
    @stop,
    @hibernate
  ]

  @transition_actions @state_entry_actions

  @state %Spark.Dsl.Entity{
    name: :state,
    target: State,
    args: [:name],
    identifier: :name,
    auto_set_fields: [entries: []],
    entities: [
      entries: @state_entry_actions
    ],
    schema: [
      name: [type: :atom, required: true],
      initial?: [type: :boolean, default: false],
      status: [type: :string],
      meaning: [type: :string]
    ]
  }

  @states %Spark.Dsl.Section{name: :states, entities: [@state]}

  @transition %Spark.Dsl.Entity{
    name: :transition,
    target: Transition,
    args: [:source, :destination],
    auto_set_fields: [actions: []],
    entities: [
      actions: @transition_actions
    ],
    schema: [
      source: [type: :atom, required: true],
      destination: [type: :atom, required: true],
      on: [type: :any, required: true],
      guard: [type: :any],
      priority: [type: :non_neg_integer, default: 0],
      reenter?: [type: :boolean, default: false],
      meaning: [type: :string]
    ]
  }

  @transitions %Spark.Dsl.Section{name: :transitions, entities: [@transition]}

  @always %Spark.Dsl.Entity{
    name: :always,
    target: AlwaysSafety,
    args: [:check],
    schema: [
      check: [type: :any, required: true],
      meaning: [type: :string]
    ]
  }

  @while_in %Spark.Dsl.Entity{
    name: :while_in,
    target: WhileInSafety,
    args: [:state, :check],
    schema: [
      state: [type: :atom, required: true],
      check: [type: :any, required: true],
      meaning: [type: :string]
    ]
  }

  @safety %Spark.Dsl.Section{name: :safety, entities: [@always, @while_in]}

  use Spark.Dsl.Extension,
    sections: [
      @machine,
      @boundary,
      @memory,
      @states,
      @transitions,
      @safety
    ],
    transformers: [Ogol.Machine.Transformers.DefineStateFunctions],
    verifiers: [Ogol.Machine.Verifiers.ValidateSpec]

  @doc false
  def validate_skill_args(args) when is_list(args) do
    if Keyword.keyword?(args) do
      args
      |> Enum.reduce_while({:ok, []}, fn
        {name, spec}, {:ok, acc} when is_atom(name) ->
          case normalize_skill_arg_spec(spec) do
            {:ok, normalized} -> {:cont, {:ok, [{name, normalized} | acc]}}
            {:error, reason} -> {:halt, {:error, "invalid skill arg #{inspect(name)}: #{reason}"}}
          end

        {_name, _spec}, _acc ->
          {:halt, {:error, "expected args to be a keyword list with atom keys"}}
      end)
      |> case do
        {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
        {:error, _reason} = error -> error
      end
    else
      {:error, "expected args to be a keyword list"}
    end
  end

  def validate_skill_args(_other), do: {:error, "expected args to be a keyword list"}

  defp normalize_skill_arg_spec(spec) when spec in @skill_arg_base_types,
    do: {:ok, [type: spec]}

  defp normalize_skill_arg_spec({:enum, values}) when is_list(values) do
    if values != [] and Enum.all?(values, &is_binary/1) do
      {:ok, [type: {:enum, values}]}
    else
      {:error, "enum values must be a non-empty list of strings"}
    end
  end

  defp normalize_skill_arg_spec(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      with {:ok, type} <- normalize_skill_arg_type(Keyword.get(opts, :type)),
           :ok <- validate_skill_arg_summary(opts),
           :ok <- validate_skill_arg_default(type, opts) do
        {:ok,
         []
         |> Keyword.put(:type, type)
         |> maybe_put_keyword(:summary, Keyword.get(opts, :summary))
         |> maybe_put_keyword(
           :default,
           Keyword.get(opts, :default, nil),
           Keyword.has_key?(opts, :default)
         )}
      end
    else
      {:error, "expected a type atom, enum tuple, or keyword options"}
    end
  end

  defp normalize_skill_arg_spec(_other),
    do: {:error, "expected a type atom, enum tuple, or keyword options"}

  defp normalize_skill_arg_type(type) when type in @skill_arg_base_types, do: {:ok, type}

  defp normalize_skill_arg_type({:enum, values}) when is_list(values) do
    if values != [] and Enum.all?(values, &is_binary/1) do
      {:ok, {:enum, values}}
    else
      {:error, "enum type must be a non-empty list of strings"}
    end
  end

  defp normalize_skill_arg_type(nil), do: {:error, "missing required :type option"}
  defp normalize_skill_arg_type(_other), do: {:error, "unsupported type"}

  defp validate_skill_arg_summary(opts) do
    case Keyword.get(opts, :summary) do
      nil -> :ok
      summary when is_binary(summary) -> :ok
      _other -> {:error, ":summary must be a string"}
    end
  end

  defp validate_skill_arg_default(type, opts) do
    if Keyword.has_key?(opts, :default) do
      default = Keyword.fetch!(opts, :default)

      if valid_skill_arg_default?(type, default) do
        :ok
      else
        {:error, ":default does not match the declared type"}
      end
    else
      :ok
    end
  end

  defp valid_skill_arg_default?(:string, value), do: is_binary(value)
  defp valid_skill_arg_default?(:integer, value), do: is_integer(value)
  defp valid_skill_arg_default?(:float, value), do: is_float(value) or is_integer(value)
  defp valid_skill_arg_default?(:boolean, value), do: is_boolean(value)
  defp valid_skill_arg_default?({:enum, values}, value), do: is_binary(value) and value in values

  defp maybe_put_keyword(opts, _key, _value, false), do: opts
  defp maybe_put_keyword(opts, key, value, true), do: Keyword.put(opts, key, value)
  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)
end
