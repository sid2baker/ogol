defmodule Ogol.Runtime.Data do
  @moduledoc false

  defstruct [
    :machine_id,
    :io_adapter,
    :io_binding,
    facts: %{},
    fields: %{},
    outputs: %{},
    meta: %{
      machine_module: nil,
      topology_id: nil,
      signal_sink: nil,
      timeout_refs: %{}
    }
  ]
end

defmodule Ogol.Runtime.DeliveredEvent do
  @moduledoc false

  defstruct [:family, :name, :data, :meta, :from]
end

defmodule Ogol.Runtime.Staging do
  @moduledoc false

  defstruct [
    :data,
    :request_from,
    :state_override,
    :stop_reason,
    reply_count: 0,
    boundary_effects: [],
    otp_actions: []
  ]
end

defmodule Ogol.Runtime.Normalize do
  @moduledoc false

  alias Ogol.Runtime.DeliveredEvent

  @spec delivered(term(), term(), Ogol.Runtime.Data.t()) ::
          DeliveredEvent.t() | {:stop, term()} | nil
  def delivered({:call, from}, {:request, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :request, name: name, data: data, meta: meta, from: from}
  end

  def delivered(:cast, {:event, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :event, name: name, data: data, meta: meta}
  end

  def delivered(:info, {:ogol_hardware_event, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :hardware, name: name, data: data, meta: meta}
  end

  def delivered(:info, %EtherCAT.Event{} = message, machine_data) do
    Ogol.Hardware.EtherCAT.normalize_message(machine_data.io_binding, message)
  end

  def delivered(:info, {:ogol_state_timeout, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :state_timeout, name: name, data: data, meta: meta}
  end

  def delivered(:internal, {:ogol_internal, name, data, meta}, _machine_data)
      when is_atom(name) and is_map(data) and is_map(meta) do
    %DeliveredEvent{family: :internal, name: name, data: data, meta: meta}
  end

  def delivered(_type, _content, _machine_data), do: nil

  @spec maybe_merge_fact_patch(Ogol.Runtime.Data.t(), DeliveredEvent.t()) :: Ogol.Runtime.Data.t()
  def maybe_merge_fact_patch(data, %DeliveredEvent{family: family, data: event_data})
      when family in [:event, :hardware] do
    fact_patch = Map.get(event_data, :facts) || Map.get(event_data, "facts")

    if is_map(fact_patch) do
      %{data | facts: Map.merge(data.facts, fact_patch)}
    else
      data
    end
  end

  def maybe_merge_fact_patch(data, _delivered), do: data
end

defmodule Ogol.Runtime.Target do
  @moduledoc false

  alias Ogol.Runtime.Data

  @type resolved_machine_runtime :: %{
          pid: pid(),
          state_name: atom(),
          data: Data.t(),
          module: module()
        }

  @spec resolve_machine_pid(pid() | atom()) :: {:ok, pid()} | {:error, term()}
  def resolve_machine_pid(target) do
    with {:ok, %{pid: pid}} <- resolve_machine_runtime(target) do
      {:ok, pid}
    end
  end

  @spec resolve_machine_pid!(pid() | atom()) :: pid()
  def resolve_machine_pid!(target) do
    case resolve_machine_pid(target) do
      {:ok, pid} ->
        pid

      {:error, {:target_unavailable, unavailable_target}} ->
        raise ArgumentError,
              "machine target #{inspect(unavailable_target)} is not available in runtime"

      {:error, reason} ->
        raise ArgumentError, "machine target #{inspect(target)} is invalid: #{inspect(reason)}"
    end
  end

  @spec resolve_machine_runtime(pid() | atom()) ::
          {:ok, resolved_machine_runtime()} | {:error, term()}
  def resolve_machine_runtime(target)

  def resolve_machine_runtime(machine_id) when is_atom(machine_id) do
    case Ogol.Machine.Registry.whereis(machine_id) do
      pid when is_pid(pid) -> resolve_machine_runtime(pid)
      nil -> {:error, {:target_unavailable, machine_id}}
    end
  end

  def resolve_machine_runtime(pid) when is_pid(pid) do
    case safe_get_state(pid) do
      {state_name, %Data{} = data} when is_atom(state_name) ->
        module = data.meta[:machine_module]

        if is_atom(module) and function_exported?(module, :skills, 0) do
          {:ok, %{pid: pid, state_name: state_name, data: data, module: module}}
        else
          {:error, {:target_unavailable, pid}}
        end

      _other ->
        {:error, {:target_unavailable, pid}}
    end
  end

  @spec machine_id(pid() | atom()) :: {:ok, atom()} | {:error, term()}
  def machine_id(target) do
    with {:ok, %{data: %Data{machine_id: machine_id}}} <- resolve_machine_runtime(target) do
      {:ok, machine_id}
    end
  end

  defp safe_get_state(pid) do
    :sys.get_state(pid)
  catch
    :exit, _reason -> nil
  end
end

defmodule Ogol.Runtime.SafetyViolation do
  defexception [:message, :check, :state]

  @impl true
  def exception(opts) do
    check = Keyword.fetch!(opts, :check)
    state = Keyword.fetch!(opts, :state)

    %__MODULE__{
      check: check,
      state: state,
      message: "safety violation #{inspect(check)} in state #{inspect(state)}"
    }
  end
end

defmodule Ogol.Runtime.Safety do
  @moduledoc false

  @spec check!(
          module(),
          [Ogol.Machine.Compiler.Model.SafetyRule.t()],
          atom(),
          Ogol.Runtime.Data.t()
        ) ::
          :ok
  def check!(module, rules, state_name, data) do
    Enum.each(rules, fn rule ->
      if applies?(rule.scope, state_name) and
           not invoke_check(module, rule.check, state_name, data) do
        raise Ogol.Runtime.SafetyViolation, check: rule.check, state: state_name
      end
    end)
  end

  defp applies?(:always, _state_name), do: true
  defp applies?({:while_in, state}, state_name), do: state == state_name

  defp invoke_check(module, {:callback, name}, state_name, data) do
    cond do
      function_exported?(module, name, 2) -> apply(module, name, [state_name, data])
      function_exported?(module, name, 1) -> apply(module, name, [data])
      true -> raise UndefinedFunctionError, module: module, function: name, arity: 2
    end
  end

  defp invoke_check(_module, value, _state_name, _data), do: value == true
end

defmodule Ogol.Runtime.Actions do
  @moduledoc false

  alias Ogol.Machine.Compiler.Model.Action
  alias Ogol.Runtime.Data
  alias Ogol.Runtime.Staging

  @spec run(module(), [Action.t()], Ogol.Runtime.DeliveredEvent.t() | nil, Data.t() | Staging.t()) ::
          {:ok, Staging.t()} | {:error, term()}
  def run(module, actions, delivered, %Data{} = data) do
    run(module, actions, delivered, %Staging{
      data: data,
      request_from: delivered && delivered.from
    })
  end

  def run(module, actions, delivered, %Staging{} = staging) do
    request_from = staging.request_from || (delivered && delivered.from)

    Enum.reduce_while(
      actions,
      {:ok, %{staging | request_from: request_from}},
      fn action, {:ok, staging} ->
        case apply_action(module, action, delivered, staging) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    )
  end

  defp apply_action(
         _module,
         %Action{kind: :set_fact, args: %{name: name, value: value}},
         _delivered,
         staging
       ) do
    next_data = %{staging.data | facts: Map.put(staging.data.facts, name, value)}
    {:ok, %{staging | data: next_data}}
  end

  defp apply_action(
         _module,
         %Action{kind: :set_field, args: %{name: name, value: value}},
         _delivered,
         staging
       ) do
    next_data = %{staging.data | fields: Map.put(staging.data.fields, name, value)}
    {:ok, %{staging | data: next_data}}
  end

  defp apply_action(
         _module,
         %Action{kind: :set_output, args: %{name: name, value: value}},
         _delivered,
         staging
       ) do
    next_data = %{staging.data | outputs: Map.put(staging.data.outputs, name, value)}

    {:ok,
     %{
       staging
       | data: next_data,
         boundary_effects: staging.boundary_effects ++ [{:output, %{name: name, value: value}}]
     }}
  end

  defp apply_action(_module, %Action{kind: :signal, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:signal, args}]}}
  end

  defp apply_action(_module, %Action{kind: :command, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:command, args}]}}
  end

  defp apply_action(_module, %Action{kind: :reply, args: %{value: value}}, _delivered, %Staging{
         request_from: nil
       }) do
    {:error, {:reply_outside_request, value}}
  end

  defp apply_action(_module, %Action{kind: :reply, args: %{value: value}}, _delivered, staging) do
    action = {:reply, staging.request_from, value}

    {:ok,
     %{
       staging
       | reply_count: staging.reply_count + 1,
         otp_actions: staging.otp_actions ++ [action]
     }}
  end

  defp apply_action(
         _module,
         %Action{kind: :internal, args: %{name: name, data: data, meta: meta}},
         _delivered,
         staging
       ) do
    action = {:next_event, :internal, {:ogol_internal, name, data, meta}}
    {:ok, %{staging | otp_actions: staging.otp_actions ++ [action]}}
  end

  defp apply_action(_module, %Action{kind: :state_timeout, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:state_timeout, args}]}}
  end

  defp apply_action(_module, %Action{kind: :cancel_timeout, args: args}, _delivered, staging) do
    {:ok, %{staging | boundary_effects: staging.boundary_effects ++ [{:cancel_timeout, args}]}}
  end

  defp apply_action(module, %Action{kind: :callback, args: %{name: name}}, delivered, staging) do
    case invoke_callback_action(module, name, delivered, staging) do
      {:ok, %Staging{} = next_staging} -> {:ok, next_staging}
      {:ok, %Ogol.Runtime.Data{} = next_data} -> {:ok, %{staging | data: next_data}}
      :ok -> {:ok, staging}
      {:error, reason} -> {:error, {:callback_failed, name, reason}}
      other -> {:error, {:invalid_callback_result, name, other}}
    end
  end

  defp apply_action(
         module,
         %Action{kind: :foreign, args: %{kind: kind, module: foreign_module, opts: opts}},
         delivered,
         staging
       ) do
    cond do
      not Code.ensure_loaded?(foreign_module) ->
        {:error, {:foreign_module_unavailable, foreign_module}}

      not function_exported?(foreign_module, :run, 5) ->
        {:error, {:foreign_module_missing_callback, foreign_module}}

      true ->
        case foreign_module.run(kind, opts, module, delivered, staging) do
          {:ok, %Staging{} = next_staging} -> {:ok, next_staging}
          {:error, reason} -> {:error, {:foreign_failed, kind, reason}}
          other -> {:error, {:invalid_foreign_result, kind, other}}
        end
    end
  end

  defp apply_action(_module, %Action{kind: :stop, args: %{reason: reason}}, _delivered, staging) do
    {:ok, %{staging | stop_reason: reason}}
  end

  defp apply_action(_module, %Action{kind: :hibernate}, _delivered, staging) do
    {:ok, %{staging | otp_actions: staging.otp_actions ++ [:hibernate]}}
  end

  defp invoke_callback_action(module, name, delivered, staging) do
    cond do
      function_exported?(module, name, 3) ->
        apply(module, name, [delivered, staging.data, staging])

      function_exported?(module, name, 2) ->
        apply(module, name, [delivered, staging.data])

      function_exported?(module, name, 1) ->
        apply(module, name, [staging.data])

      true ->
        raise UndefinedFunctionError, module: module, function: name, arity: 3
    end
  end
end

defmodule Ogol.Runtime.CommandGateway do
  @moduledoc false

  alias Ogol.Runtime
  alias Ogol.Runtime.Notifier, as: RuntimeNotifier
  alias Ogol.Runtime.Target

  @default_timeout 5_000

  @spec invoke(atom(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(machine_id, name, data \\ %{}, opts \\ [])
      when is_atom(machine_id) and is_atom(name) and is_map(data) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    meta = Keyword.get(opts, :meta, %{})
    operator_meta = operator_meta(meta)

    with {:ok, runtime} <- Target.resolve_machine_runtime(machine_id),
         {:ok, skill} <- find_skill(runtime.module, name),
         {:ok, reply} <- dispatch(runtime.pid, skill, name, data, operator_meta, timeout) do
      RuntimeNotifier.emit(:operator_skill_invoked,
        machine_id: machine_id,
        source: __MODULE__,
        payload: %{name: name, kind: skill.kind, data: data, reply: reply},
        meta: operator_meta
      )

      {:ok, reply}
    else
      {:error, reason} = error ->
        emit_failure(machine_id, name, data, operator_meta, reason)
        error
    end
  end

  defp find_skill(target_module, name) do
    case Enum.find(target_module.skills(), &(&1.name == name)) do
      %Ogol.Machine.Skill{} = skill -> {:ok, skill}
      nil -> {:error, {:unknown_skill, name}}
    end
  end

  defp dispatch(pid, %Ogol.Machine.Skill{kind: :request}, name, data, meta, timeout) do
    {:ok, Runtime.request(pid, name, data, meta, timeout)}
  catch
    :exit, reason -> {:error, {:target_runtime_failure, reason}}
  end

  defp dispatch(pid, %Ogol.Machine.Skill{kind: :event}, name, data, meta, _timeout) do
    :ok = Runtime.event(pid, name, data, meta)
    {:ok, :accepted}
  end

  defp emit_failure(machine_id, name, data, meta, reason) do
    RuntimeNotifier.emit(:operator_skill_failed,
      machine_id: machine_id,
      source: __MODULE__,
      payload: %{name: name, data: data, reason: reason},
      meta: meta
    )

    {:error, reason}
  end

  defp operator_meta(meta) do
    meta
    |> Map.put_new(:origin, :operator)
    |> Map.put_new(:gateway, __MODULE__)
  end
end
