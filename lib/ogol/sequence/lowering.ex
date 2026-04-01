defmodule Ogol.Sequence.Lowering do
  @moduledoc false

  alias Ogol.Sequence.Model

  @default_poll_interval_ms 50
  @begin_event :sequence_begin
  @advance_event :sequence_advanced
  @failure_event :sequence_failed
  @wait_poll_timeout :sequence_wait_poll
  @wait_deadline_timeout :sequence_wait_deadline

  defmodule RuntimeStep do
    @moduledoc false

    defstruct [
      :state_name,
      :kind,
      :step,
      :next_state,
      :procedure_label,
      :handler_name,
      :timeout_handler_name
    ]
  end

  @type lowered_source :: %{
          module: module(),
          source: String.t(),
          machine_name: atom()
        }

  @spec lower_to_machine_source(Model.t() | module(), keyword()) ::
          {:ok, lowered_source()} | {:error, [String.t()]}
  def lower_to_machine_source(sequence_or_model, opts \\ []) when is_list(opts) do
    with {:ok, model} <- fetch_model(sequence_or_model),
         :ok <- ensure_supported(model) do
      {:ok, build_lowered_source(model, opts)}
    end
  end

  defp fetch_model(%Model{} = model), do: {:ok, model}

  defp fetch_model(module) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, ["sequence module #{inspect(module)} is not loaded"]}

      not function_exported?(module, :__ogol_sequence__, 0) ->
        {:error, ["module #{inspect(module)} does not expose a compiled sequence model"]}

      true ->
        {:ok, module.__ogol_sequence__()}
    end
  end

  defp ensure_supported(%Model{sequence: sequence}) do
    diagnostics =
      collect_invariant_diagnostics(sequence.invariants) ++
        collect_step_diagnostics(sequence.root) ++
        Enum.flat_map(sequence.procedures, &collect_step_diagnostics(&1.body))

    case diagnostics do
      [] -> :ok
      _ -> {:error, diagnostics}
    end
  end

  defp collect_invariant_diagnostics(invariants) do
    Enum.flat_map(invariants, fn invariant ->
      collect_expr_diagnostics(
        invariant.condition,
        "sequence lowering does not support #{expr_kind(invariant.condition)} in invariant #{inspect(invariant.id)}"
      )
    end)
  end

  defp collect_step_diagnostics(steps) do
    Enum.flat_map(steps, fn step ->
      step_diagnostics(step) ++
        collect_expr_diagnostics(
          step.guard,
          "sequence lowering does not support #{expr_kind(step.guard)} in guard for #{inspect(step.id)}"
        )
    end)
  end

  defp step_diagnostics(%Model.Step{kind: :wait_signal, id: id}) do
    ["sequence lowering does not support signal waits yet: #{inspect(id)}"]
  end

  defp step_diagnostics(%Model.Step{kind: :wait_status, id: id, condition: condition}) do
    collect_expr_diagnostics(
      condition,
      "sequence lowering does not support #{expr_kind(condition)} in wait condition for #{inspect(id)}"
    )
  end

  defp step_diagnostics(%Model.Step{kind: :repeat, body: body}) do
    collect_step_diagnostics(body)
  end

  defp step_diagnostics(%Model.Step{}), do: []

  defp collect_expr_diagnostics(nil, _message), do: []
  defp collect_expr_diagnostics(value, _message) when is_boolean(value), do: []
  defp collect_expr_diagnostics(value, _message) when is_integer(value), do: []
  defp collect_expr_diagnostics(value, _message) when is_float(value), do: []
  defp collect_expr_diagnostics(value, _message) when is_binary(value), do: []
  defp collect_expr_diagnostics(%Model.StatusRef{}, _message), do: []

  defp collect_expr_diagnostics(%Model.Expr.Not{expr: expr}, message) do
    collect_expr_diagnostics(expr, message)
  end

  defp collect_expr_diagnostics(%Model.Expr.And{left: left, right: right}, message) do
    collect_expr_diagnostics(left, message) ++ collect_expr_diagnostics(right, message)
  end

  defp collect_expr_diagnostics(%Model.Expr.Or{left: left, right: right}, message) do
    collect_expr_diagnostics(left, message) ++ collect_expr_diagnostics(right, message)
  end

  defp collect_expr_diagnostics(%Model.Expr.Compare{left: left, right: right}, message) do
    collect_expr_diagnostics(left, message) ++ collect_expr_diagnostics(right, message)
  end

  defp collect_expr_diagnostics(%Model.SignalRef{}, message), do: [message]
  defp collect_expr_diagnostics(%Model.TopologyRef{}, message), do: [message]
  defp collect_expr_diagnostics(_other, message), do: [message]

  defp expr_kind(nil), do: "nil expressions"
  defp expr_kind(%Model.SignalRef{}), do: "signal references"
  defp expr_kind(%Model.TopologyRef{}), do: "topology-visible references"
  defp expr_kind(_), do: "this expression form"

  defp build_lowered_source(%Model{sequence: sequence} = model, opts) do
    module = Keyword.get(opts, :module, default_runtime_module(model))
    machine_name = Keyword.get(opts, :machine_name, sequence.name)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)

    procedures_by_id = Map.new(sequence.procedures, &{&1.id, &1})

    {entry_state, runtime_steps} =
      lower_steps(sequence.root, :completed, procedures_by_id, [:root], "root")

    source =
      module_ast(
        module,
        machine_name,
        sequence,
        entry_state,
        runtime_steps,
        poll_interval_ms
      )
      |> Macro.to_string()
      |> Code.format_string!()
      |> IO.iodata_to_binary()

    %{module: module, source: source, machine_name: machine_name}
  end

  defp default_runtime_module(%Model{module: nil, sequence: sequence}) do
    Module.concat([
      Ogol,
      Generated,
      SequenceRuntime,
      Macro.camelize(to_string(sequence.name))
    ])
  end

  defp default_runtime_module(%Model{module: module}) do
    Module.concat(module, RuntimeMachine)
  end

  defp lower_steps(steps, next_state, procedures_by_id, path, procedure_label) do
    Enum.reduce(Enum.reverse(Enum.with_index(steps, 1)), {next_state, []}, fn {step, index},
                                                                              {current_next, acc} ->
      occurrence_path = path ++ [index]
      lower_step(step, current_next, procedures_by_id, occurrence_path, procedure_label, acc)
    end)
  end

  defp lower_step(
         %Model.Step{kind: :do_skill} = step,
         next_state,
         _procedures,
         path,
         procedure_label,
         acc
       ) do
    runtime = runtime_step(step, path, next_state, procedure_label)
    {runtime.state_name, [runtime | acc]}
  end

  defp lower_step(
         %Model.Step{kind: :wait_status} = step,
         next_state,
         _procedures,
         path,
         procedure_label,
         acc
       ) do
    runtime = runtime_step(step, path, next_state, procedure_label)
    {runtime.state_name, [runtime | acc]}
  end

  defp lower_step(
         %Model.Step{kind: :fail} = step,
         _next_state,
         _procedures,
         path,
         procedure_label,
         acc
       ) do
    runtime = runtime_step(step, path, :failed, procedure_label)
    {runtime.state_name, [runtime | acc]}
  end

  defp lower_step(
         %Model.Step{kind: :run_procedure, procedure: procedure_id} = step,
         next_state,
         procedures_by_id,
         path,
         procedure_label,
         acc
       ) do
    procedure = Map.fetch!(procedures_by_id, procedure_id)

    {procedure_entry, procedure_steps} =
      lower_steps(
        procedure.body,
        next_state,
        procedures_by_id,
        path ++ [:procedure, procedure.name],
        Atom.to_string(procedure.name)
      )

    runtime = runtime_step(step, path, procedure_entry, procedure_label)
    {runtime.state_name, [runtime | procedure_steps] ++ acc}
  end

  defp lower_step(
         %Model.Step{kind: :repeat} = step,
         _next_state,
         procedures_by_id,
         path,
         procedure_label,
         acc
       ) do
    gate = runtime_step(step, path, nil, procedure_label)

    {body_entry, body_steps} =
      lower_steps(
        step.body || [],
        gate.state_name,
        procedures_by_id,
        path ++ [:repeat],
        procedure_label
      )

    runtime = %{gate | next_state: body_entry}
    {runtime.state_name, [runtime | body_steps] ++ acc}
  end

  defp runtime_step(step, path, next_state, procedure_label) do
    suffix = sanitize_identifier(path)
    state_name = String.to_atom("sequence_#{suffix}")
    handler_name = String.to_atom("__sequence_step_#{suffix}__")
    timeout_handler_name = String.to_atom("__sequence_timeout_#{suffix}__")

    %RuntimeStep{
      state_name: state_name,
      kind: step.kind,
      step: step,
      next_state: next_state,
      procedure_label: procedure_label,
      handler_name: handler_name,
      timeout_handler_name: timeout_handler_name
    }
  end

  defp sanitize_identifier(path) do
    path
    |> Enum.map(fn
      part when is_atom(part) -> Atom.to_string(part)
      part -> to_string(part)
    end)
    |> Enum.join("_")
    |> String.replace(~r/[^a-zA-Z0-9_]+/, "_")
  end

  defp module_ast(
         module,
         machine_name,
         sequence,
         entry_state,
         runtime_steps,
         poll_interval_ms
       ) do
    base_states = base_state_defs()
    runtime_state_defs = Enum.map(runtime_steps, &step_state_ast(&1))
    base_transitions = start_transitions(entry_state) ++ stop_transitions(runtime_steps)
    runtime_transition_defs = Enum.flat_map(runtime_steps, &step_transition_asts(&1))
    helper_defs = helper_asts(sequence, runtime_steps, poll_interval_ms)

    quote do
      defmodule unquote(module) do
        use Ogol.Machine

        @moduledoc false

        machine do
          name(unquote(machine_name))
          unquote_splicing(sequence_meaning_asts(sequence.meaning))
        end

        boundary do
          request(:start)
          request(:stop)
          signal(:started)
          signal(:stopped)
          signal(:completed)
          signal(:failed)
        end

        memory do
          field(:running?, :boolean, default: false, public?: true)
          field(:phase, :atom, default: :idle, public?: true)
          field(:current_procedure, :string, default: nil, public?: true)
          field(:current_step_id, :string, default: nil, public?: true)
          field(:blocked_on, :string, default: nil, public?: true)
          field(:failure_message, :string, default: nil, public?: true)
        end

        states do
          (unquote_splicing(base_states ++ runtime_state_defs))
        end

        transitions do
          (unquote_splicing(base_transitions ++ runtime_transition_defs))
        end

        unquote_splicing(helper_defs)
      end
    end
  end

  defp sequence_meaning_asts(nil), do: []

  defp sequence_meaning_asts(meaning) do
    [
      quote do
        meaning(unquote(meaning))
      end
    ]
  end

  defp base_state_defs do
    [
      quote do
        state :idle do
          initial?(true)
          set_field(:running?, false)
          set_field(:phase, :idle)
          set_field(:current_procedure, nil)
          set_field(:current_step_id, nil)
          set_field(:blocked_on, nil)
        end
      end,
      quote do
        state :completed do
          set_field(:running?, false)
          set_field(:phase, :completed)
          set_field(:blocked_on, nil)
          signal(:completed)
        end
      end,
      quote do
        state :failed do
          set_field(:running?, false)
          set_field(:phase, :failed)
          set_field(:blocked_on, nil)
          signal(:failed)
        end
      end
    ]
  end

  defp step_state_ast(%RuntimeStep{} = runtime) do
    step = runtime.step
    timeout = step.timeout && step.timeout.duration_ms

    quote do
      state unquote(runtime.state_name) do
        set_field(:running?, true)
        set_field(:phase, :running)
        set_field(:current_procedure, unquote(runtime.procedure_label))
        set_field(:current_step_id, unquote(step.id))
        set_field(:blocked_on, unquote(blocked_on_value(runtime)))
        internal(unquote(@begin_event))
        unquote_splicing(wait_timeout_entry_asts(timeout))
      end
    end
  end

  defp blocked_on_value(%RuntimeStep{kind: :wait_status, step: step}) do
    Map.get(step.projection, :label) || "Wait for condition"
  end

  defp blocked_on_value(_runtime), do: nil

  defp wait_timeout_entry_asts(nil), do: []

  defp wait_timeout_entry_asts(duration_ms) do
    [
      quote do
        state_timeout(unquote(@wait_deadline_timeout), unquote(duration_ms))
      end
    ]
  end

  defp start_transitions(entry_state) do
    Enum.map([:idle, :completed, :failed], fn source ->
      quote do
        transition unquote(source), unquote(entry_state) do
          on({:request, :start})
          cancel_timeout(unquote(@wait_poll_timeout))
          cancel_timeout(unquote(@wait_deadline_timeout))
          set_field(:failure_message, nil)
          set_field(:blocked_on, nil)
          signal(:started)
          reply(:ok)
        end
      end
    end)
  end

  defp stop_transitions(runtime_steps) do
    step_sources = Enum.map(runtime_steps, & &1.state_name)

    Enum.map([:idle, :completed, :failed | step_sources], fn source ->
      quote do
        transition unquote(source), :idle do
          on({:request, :stop})
          cancel_timeout(unquote(@wait_poll_timeout))
          cancel_timeout(unquote(@wait_deadline_timeout))
          set_field(:failure_message, nil)
          set_field(:blocked_on, nil)
          signal(:stopped)
          reply(:ok)
        end
      end
    end)
  end

  defp step_transition_asts(%RuntimeStep{kind: :do_skill} = runtime) do
    [
      quote do
        transition unquote(runtime.state_name), unquote(runtime.state_name) do
          on({:internal, unquote(@begin_event)})
          callback(unquote(runtime.handler_name))
        end
      end,
      quote do
        transition unquote(runtime.state_name), unquote(runtime.next_state) do
          on({:internal, unquote(@advance_event)})
        end
      end,
      quote do
        transition unquote(runtime.state_name), :failed do
          on({:internal, unquote(@failure_event)})
          callback(:__sequence_record_failure__)
        end
      end
    ]
  end

  defp step_transition_asts(%RuntimeStep{kind: :wait_status} = runtime) do
    timeout_transition =
      if runtime.step.timeout do
        [
          quote do
            transition unquote(runtime.state_name), :failed do
              on({:state_timeout, unquote(@wait_deadline_timeout)})
              cancel_timeout(unquote(@wait_poll_timeout))
              callback(unquote(runtime.timeout_handler_name))
            end
          end
        ]
      else
        []
      end

    [
      quote do
        transition unquote(runtime.state_name), unquote(runtime.state_name) do
          on({:internal, unquote(@begin_event)})
          callback(unquote(runtime.handler_name))
        end
      end,
      quote do
        transition unquote(runtime.state_name), unquote(runtime.state_name) do
          on({:state_timeout, unquote(@wait_poll_timeout)})
          callback(unquote(runtime.handler_name))
        end
      end,
      quote do
        transition unquote(runtime.state_name), unquote(runtime.next_state) do
          on({:internal, unquote(@advance_event)})
          cancel_timeout(unquote(@wait_poll_timeout))
          cancel_timeout(unquote(@wait_deadline_timeout))
        end
      end,
      quote do
        transition unquote(runtime.state_name), :failed do
          on({:internal, unquote(@failure_event)})
          cancel_timeout(unquote(@wait_poll_timeout))
          cancel_timeout(unquote(@wait_deadline_timeout))
          callback(:__sequence_record_failure__)
        end
      end
      | timeout_transition
    ]
  end

  defp step_transition_asts(%RuntimeStep{kind: kind} = runtime)
       when kind in [:run_procedure, :repeat] do
    [
      quote do
        transition unquote(runtime.state_name), unquote(runtime.state_name) do
          on({:internal, unquote(@begin_event)})
          callback(unquote(runtime.handler_name))
        end
      end,
      quote do
        transition unquote(runtime.state_name), unquote(runtime.next_state) do
          on({:internal, unquote(@advance_event)})
        end
      end,
      quote do
        transition unquote(runtime.state_name), :failed do
          on({:internal, unquote(@failure_event)})
          callback(:__sequence_record_failure__)
        end
      end
    ]
  end

  defp step_transition_asts(%RuntimeStep{kind: :fail} = runtime) do
    [
      quote do
        transition unquote(runtime.state_name), :failed do
          on({:internal, unquote(@begin_event)})
          callback(unquote(runtime.handler_name))
        end
      end
    ]
  end

  defp helper_asts(sequence, runtime_steps, poll_interval_ms) do
    invariants =
      Enum.map(sequence.invariants, fn invariant ->
        {invariant.condition, invariant_message(invariant)}
      end)

    [
      generic_helper_ast(invariants),
      Enum.map(runtime_steps, &step_handler_ast(&1, poll_interval_ms))
    ]
    |> List.flatten()
  end

  defp invariant_message(%Model.Invariant{meaning: meaning})
       when is_binary(meaning) and byte_size(meaning) > 0,
       do: meaning

  defp invariant_message(%Model.Invariant{id: id}), do: "Invariant violated: #{id}"

  defp step_handler_ast(%RuntimeStep{kind: :do_skill} = runtime, _poll_interval_ms) do
    %Model.Step{
      target: %Model.SkillRef{machine: machine, skill: skill},
      guard: guard,
      timeout: timeout,
      projection: projection
    } = runtime.step

    label = Map.get(projection, :label) || "Invoke #{machine}.#{skill}"

    quote do
      def unquote(runtime.handler_name)(_delivered, _data, staging) do
        with :ok <- __sequence_check_invariants__(),
             :ok <-
               __sequence_check_guard__(
                 unquote(Macro.escape(guard)),
                 unquote(precondition_message(label))
               ),
             {:ok, _result} <-
               Ogol.Runtime.invoke(
                 unquote(machine),
                 unquote(skill),
                 %{},
                 timeout: unquote(timeout_value(timeout))
               ) do
          {:ok, __sequence_enqueue_internal__(staging, unquote(@advance_event))}
        else
          {:error, reason} ->
            {:ok,
             __sequence_enqueue_failure__(
               staging,
               __sequence_reason_message__(reason, unquote("#{label} failed"))
             )}
        end
      end
    end
  end

  defp step_handler_ast(%RuntimeStep{kind: :wait_status} = runtime, poll_interval_ms) do
    %Model.Step{
      condition: condition,
      guard: guard,
      on_timeout: on_timeout,
      projection: projection
    } =
      runtime.step

    label = Map.get(projection, :label) || "Wait for condition"

    [
      quote do
        def unquote(runtime.handler_name)(_delivered, _data, staging) do
          with :ok <- __sequence_check_invariants__(),
               :ok <-
                 __sequence_check_guard__(
                   unquote(Macro.escape(guard)),
                   unquote(precondition_message(label))
                 ),
               {:ok, true} <- __sequence_eval_boolean__(unquote(Macro.escape(condition))) do
            {:ok, __sequence_enqueue_internal__(staging, unquote(@advance_event))}
          else
            {:ok, false} ->
              {:ok, __sequence_schedule_poll__(staging, unquote(poll_interval_ms))}

            {:error, reason} ->
              {:ok,
               __sequence_enqueue_failure__(
                 staging,
                 __sequence_reason_message__(reason, unquote("#{label} failed"))
               )}
          end
        end
      end,
      quote do
        def unquote(runtime.timeout_handler_name)(_delivered, _data, staging) do
          {:ok, __sequence_mark_failure__(staging, unquote(timeout_message(on_timeout, label)))}
        end
      end
    ]
  end

  defp step_handler_ast(%RuntimeStep{kind: kind} = runtime, _poll_interval_ms)
       when kind in [:run_procedure, :repeat] do
    label = Map.get(runtime.step.projection, :label) || "Run step"

    quote do
      def unquote(runtime.handler_name)(_delivered, _data, staging) do
        with :ok <- __sequence_check_invariants__(),
             :ok <-
               __sequence_check_guard__(
                 unquote(Macro.escape(runtime.step.guard)),
                 unquote(precondition_message(label))
               ) do
          {:ok, __sequence_enqueue_internal__(staging, unquote(@advance_event))}
        else
          {:error, reason} ->
            {:ok,
             __sequence_enqueue_failure__(
               staging,
               __sequence_reason_message__(reason, unquote("#{label} failed"))
             )}
        end
      end
    end
  end

  defp step_handler_ast(%RuntimeStep{kind: :fail} = runtime, _poll_interval_ms) do
    message =
      runtime.step.message || Map.get(runtime.step.projection, :label) || "Sequence failed"

    quote do
      def unquote(runtime.handler_name)(_delivered, _data, staging) do
        {:ok, __sequence_mark_failure__(staging, unquote(message))}
      end
    end
  end

  defp generic_helper_ast(invariants) do
    quote do
      def __sequence_record_failure__(delivered, _data, staging) do
        message =
          case delivered do
            %Ogol.Runtime.DeliveredEvent{data: data} when is_map(data) ->
              Map.get(data, :message) || Map.get(data, "message") || "Sequence failed"

            _ ->
              "Sequence failed"
          end

        {:ok, __sequence_mark_failure__(staging, message)}
      end

      defp __sequence_mark_failure__(staging, message) do
        next_data = %{
          staging.data
          | fields: Map.put(staging.data.fields, :failure_message, message)
        }

        %{staging | data: next_data}
      end

      defp __sequence_enqueue_failure__(staging, message) do
        staging
        |> __sequence_mark_failure__(message)
        |> __sequence_enqueue_internal__(unquote(@failure_event), %{message: message})
      end

      defp __sequence_enqueue_internal__(staging, name, data \\ %{}, meta \\ %{}) do
        action = {:next_event, :internal, {:ogol_internal, name, data, meta}}
        %{staging | otp_actions: staging.otp_actions ++ [action]}
      end

      defp __sequence_schedule_poll__(staging, delay_ms) do
        effect =
          {:state_timeout,
           %{name: unquote(@wait_poll_timeout), delay_ms: delay_ms, data: %{}, meta: %{}}}

        %{staging | boundary_effects: staging.boundary_effects ++ [effect]}
      end

      defp __sequence_check_invariants__ do
        Enum.reduce_while(unquote(Macro.escape(invariants)), :ok, fn {expr, message}, :ok ->
          case __sequence_eval_boolean__(expr) do
            {:ok, true} -> {:cont, :ok}
            {:ok, false} -> {:halt, {:error, message}}
            {:error, reason} -> {:halt, {:error, __sequence_reason_message__(reason, message)}}
          end
        end)
      end

      defp __sequence_check_guard__(nil, _message), do: :ok

      defp __sequence_check_guard__(expr, message) do
        case __sequence_eval_boolean__(expr) do
          {:ok, true} -> :ok
          {:ok, false} -> {:error, message}
          {:error, reason} -> {:error, __sequence_reason_message__(reason, message)}
        end
      end

      defp __sequence_eval_boolean__(value) when is_boolean(value), do: {:ok, value}

      defp __sequence_eval_boolean__(%Ogol.Sequence.Model.StatusRef{} = ref) do
        case __sequence_eval_value__(ref) do
          {:ok, value} -> {:ok, value == true}
          {:error, reason} -> {:error, reason}
        end
      end

      defp __sequence_eval_boolean__(%Ogol.Sequence.Model.Expr.Not{expr: expr}) do
        case __sequence_eval_boolean__(expr) do
          {:ok, value} -> {:ok, not value}
          {:error, reason} -> {:error, reason}
        end
      end

      defp __sequence_eval_boolean__(%Ogol.Sequence.Model.Expr.And{left: left, right: right}) do
        with {:ok, left_value} <- __sequence_eval_boolean__(left),
             {:ok, right_value} <- __sequence_eval_boolean__(right) do
          {:ok, left_value and right_value}
        end
      end

      defp __sequence_eval_boolean__(%Ogol.Sequence.Model.Expr.Or{left: left, right: right}) do
        with {:ok, left_value} <- __sequence_eval_boolean__(left),
             {:ok, right_value} <- __sequence_eval_boolean__(right) do
          {:ok, left_value or right_value}
        end
      end

      defp __sequence_eval_boolean__(%Ogol.Sequence.Model.Expr.Compare{} = expr) do
        with {:ok, left_value} <- __sequence_eval_value__(expr.left),
             {:ok, right_value} <- __sequence_eval_value__(expr.right) do
          {:ok, __sequence_compare__(expr.op, left_value, right_value)}
        end
      end

      defp __sequence_eval_boolean__(other), do: {:error, {:unsupported_boolean_expr, other}}

      defp __sequence_eval_value__(value)
           when is_boolean(value) or is_integer(value) or is_float(value) or is_binary(value),
           do: {:ok, value}

      defp __sequence_eval_value__(%Ogol.Sequence.Model.StatusRef{machine: machine, item: item}) do
        __sequence_status_value__(machine, item)
      end

      defp __sequence_eval_value__(%Ogol.Sequence.Model.Expr.Compare{} = expr) do
        __sequence_eval_boolean__(expr)
      end

      defp __sequence_eval_value__(other), do: {:error, {:unsupported_value_expr, other}}

      defp __sequence_status_value__(machine, item) do
        case Ogol.Runtime.Target.resolve_machine_runtime(machine) do
          {:ok, %{data: %Ogol.Runtime.Data{} = data}} ->
            {:ok, __sequence_pick_data_item__(data, item)}

          {:error, _reason} ->
            {:error, {:machine_unavailable, machine}}
        end
      end

      defp __sequence_pick_data_item__(data, item) do
        cond do
          Map.has_key?(data.facts, item) -> Map.get(data.facts, item)
          Map.has_key?(data.outputs, item) -> Map.get(data.outputs, item)
          Map.has_key?(data.fields, item) -> Map.get(data.fields, item)
          true -> nil
        end
      end

      defp __sequence_compare__(op, left, right) do
        try do
          case op do
            :== -> left == right
            :!= -> left != right
            :< -> left < right
            :<= -> left <= right
            :> -> left > right
            :>= -> left >= right
          end
        rescue
          _error -> false
        end
      end

      defp __sequence_reason_message__(message, _prefix) when is_binary(message), do: message

      defp __sequence_reason_message__({:machine_unavailable, machine}, prefix) do
        "#{prefix}: machine #{inspect(machine)} is unavailable"
      end

      defp __sequence_reason_message__({:unsupported_boolean_expr, expr}, prefix) do
        "#{prefix}: unsupported boolean expression #{inspect(expr)}"
      end

      defp __sequence_reason_message__({:unsupported_value_expr, expr}, prefix) do
        "#{prefix}: unsupported value expression #{inspect(expr)}"
      end

      defp __sequence_reason_message__(reason, prefix) do
        "#{prefix}: #{inspect(reason)}"
      end
    end
  end

  defp timeout_value(nil), do: 5_000
  defp timeout_value(%Model.TimeoutSpec{duration_ms: duration_ms}), do: duration_ms

  defp timeout_message(%Model.Failure{message: message}, _label) when is_binary(message),
    do: message

  defp timeout_message(_failure, label), do: "#{label} timed out"

  defp precondition_message(label), do: "#{label} precondition was false"
end
