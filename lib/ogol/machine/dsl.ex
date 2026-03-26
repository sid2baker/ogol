defmodule Ogol.Machine.Dsl do
  @moduledoc false

  defmodule MachineOptions do
    defstruct [
      :name,
      :meaning,
      :hardware_adapter,
      :hardware_opts,
      :__spark_metadata__
    ]
  end

  defmodule Fact do
    defstruct [:name, :type, :default, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule Event do
    defstruct [:name, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule Request do
    defstruct [:name, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule Command do
    defstruct [:name, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule Output do
    defstruct [:name, :type, :default, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule Signal do
    defstruct [:name, :meaning, :__identifier__, :__spark_metadata__]
  end

  defmodule Field do
    defstruct [:name, :type, :default, :meaning, :__identifier__, :__spark_metadata__]
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

  defmodule SendEvent do
    defstruct [:target, :name, :data, :meta, :__spark_metadata__]
  end

  defmodule SendRequest do
    defstruct [:target, :name, :data, :meta, :timeout, :__spark_metadata__]
  end

  defmodule Monitor do
    defstruct [:target, :name, :__spark_metadata__]
  end

  defmodule Demonitor do
    defstruct [:name, :__spark_metadata__]
  end

  defmodule Link do
    defstruct [:target, :__spark_metadata__]
  end

  defmodule Unlink do
    defstruct [:target, :__spark_metadata__]
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

  defmodule Child do
    defstruct [
      :name,
      :machine,
      :opts,
      :restart,
      :state_bindings,
      :signal_bindings,
      :down_binding,
      :meaning,
      :__identifier__,
      :__spark_metadata__
    ]
  end

  @machine %Spark.Dsl.Section{
    name: :machine,
    schema: [
      name: [type: :atom, doc: "Optional machine name override."],
      meaning: [type: :string, doc: "Human-readable machine meaning."],
      hardware_adapter: [type: :atom, doc: "Default hardware adapter module."],
      hardware_opts: [type: :keyword_list, default: [], doc: "Default hardware adapter options."]
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
      meaning: [type: :string]
    ]
  }

  @event %Spark.Dsl.Entity{
    name: :event,
    target: Event,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      meaning: [type: :string]
    ]
  }

  @request %Spark.Dsl.Entity{
    name: :request,
    target: Request,
    args: [:name],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      meaning: [type: :string]
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
      meaning: [type: :string]
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
      meaning: [type: :string]
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

  @send_event %Spark.Dsl.Entity{
    name: :send_event,
    target: SendEvent,
    args: [:target, :name],
    schema: [
      target: [type: :atom, required: true],
      name: [type: :atom, required: true],
      data: [type: :map, default: %{}],
      meta: [type: :map, default: %{}]
    ]
  }

  @send_request %Spark.Dsl.Entity{
    name: :send_request,
    target: SendRequest,
    args: [:target, :name],
    schema: [
      target: [type: :atom, required: true],
      name: [type: :atom, required: true],
      data: [type: :map, default: %{}],
      meta: [type: :map, default: %{}],
      timeout: [type: :timeout, default: 5_000]
    ]
  }

  @monitor %Spark.Dsl.Entity{
    name: :monitor,
    target: Monitor,
    args: [:target, :name],
    schema: [
      target: [type: :any, required: true],
      name: [type: :atom, required: true]
    ]
  }

  @demonitor %Spark.Dsl.Entity{
    name: :demonitor,
    target: Demonitor,
    args: [:name],
    schema: [
      name: [type: :atom, required: true]
    ]
  }

  @link %Spark.Dsl.Entity{
    name: :link,
    target: Link,
    args: [:target],
    schema: [
      target: [type: :any, required: true]
    ]
  }

  @unlink %Spark.Dsl.Entity{
    name: :unlink,
    target: Unlink,
    args: [:target],
    schema: [
      target: [type: :any, required: true]
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
    @monitor,
    @demonitor,
    @link,
    @unlink,
    @callback_action,
    @foreign_action,
    @stop,
    @hibernate
  ]

  @transition_actions @state_entry_actions ++ [@send_event, @send_request]

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

  @child %Spark.Dsl.Entity{
    name: :child,
    target: Child,
    args: [:name, :machine],
    identifier: :name,
    schema: [
      name: [type: :atom, required: true],
      machine: [type: {:or, [:atom, :module]}, required: true],
      opts: [type: :keyword_list, default: []],
      restart: [type: :atom, default: :permanent],
      state_bindings: [type: :keyword_list, default: []],
      signal_bindings: [type: :keyword_list, default: []],
      down_binding: [type: :atom],
      meaning: [type: :string]
    ]
  }

  @children %Spark.Dsl.Section{name: :children, entities: [@child]}

  use Spark.Dsl.Extension,
    sections: [
      @machine,
      @boundary,
      @memory,
      @states,
      @transitions,
      @safety,
      @children
    ],
    transformers: [Ogol.Machine.Transformers.DefineStateFunctions],
    verifiers: [Ogol.Machine.Verifiers.ValidateSpec]
end
