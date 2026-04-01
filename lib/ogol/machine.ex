defmodule Ogol.Machine do
  @moduledoc """
  Spark-backed authoring entrypoint for Ogol machine modules.

  Machine modules compile directly into generated `:gen_statem` runtimes.
  """

  use Spark.Dsl,
    default_extensions: [
      extensions: [Ogol.Machine.Dsl]
    ]

  def handle_before_compile(_opts) do
    quote generated: true do
      require Ogol.Machine.Compiler.Generate
      Ogol.Machine.Compiler.Generate.inject()

      defp __ogol_init_data__(machine, opts) do
        resolved_io_binding = Keyword.get(opts, :io_binding)

        adapter =
          Keyword.get(opts, :io_adapter) ||
            Ogol.Hardware.adapter_for(resolved_io_binding)

        normalized_io_binding = Ogol.Hardware.normalize_binding(adapter, resolved_io_binding)

        %Ogol.Runtime.Data{
          machine_id: Keyword.get(opts, :machine_id, machine.name),
          io_adapter: adapter,
          io_binding: normalized_io_binding,
          facts: machine.facts,
          fields: machine.fields,
          outputs: machine.outputs,
          meta: %{
            machine_module: __MODULE__,
            topology_id: Keyword.get(opts, :topology_id),
            signal_sink: Keyword.get(opts, :signal_sink),
            timeout_refs: %{}
          }
        }
      end

      defp __ogol_stage_state_entry__(state_name, staging_or_data) do
        machine = __ogol_machine__()
        state = Map.fetch!(machine.states, state_name)
        Ogol.Runtime.Actions.run(__MODULE__, state.entries, nil, staging_or_data)
      end

      defp __ogol_handle_state_event__(state_name, delivered, data, transitions) do
        working_data = Ogol.Runtime.Normalize.maybe_merge_fact_patch(data, delivered)
        __ogol_maybe_notify_delivered__(working_data, delivered)

        case __ogol_match_transition__(delivered, working_data, transitions) do
          {:match, transition} ->
            __ogol_apply_transition__(state_name, delivered, working_data, transition)

          :no_match ->
            __ogol_default_unmatched__(state_name, delivered, working_data)
        end
      end

      defp __ogol_match_transition__(_delivered, _data, []), do: :no_match

      defp __ogol_match_transition__(delivered, data, [transition | rest]) do
        if __ogol_transition_matches__(delivered, data, transition) do
          {:match, transition}
        else
          __ogol_match_transition__(delivered, data, rest)
        end
      end

      defp __ogol_transition_matches__(delivered, data, transition) do
        trigger_matches?(delivered, transition.trigger) and
          __ogol_eval_guard__(delivered, data, transition.guard)
      end

      defp trigger_matches?(
             %Ogol.Runtime.DeliveredEvent{family: family, name: name},
             {family, name}
           ),
           do: true

      defp trigger_matches?(_, _), do: false

      defp __ogol_eval_guard__(_delivered, _data, nil), do: true

      defp __ogol_eval_guard__(delivered, data, {:callback, name}) do
        cond do
          function_exported?(__MODULE__, name, 2) -> apply(__MODULE__, name, [delivered, data])
          function_exported?(__MODULE__, name, 1) -> apply(__MODULE__, name, [data])
          true -> raise UndefinedFunctionError, module: __MODULE__, function: name, arity: 2
        end
      end

      defp __ogol_eval_guard__(_delivered, _data, value), do: value == true

      defp __ogol_apply_transition__(from_state, delivered, data, transition) do
        try do
          with {:ok, staging} <-
                 Ogol.Runtime.Actions.run(__MODULE__, transition.actions, delivered, data),
               {:ok, state_after_commit} <-
                 __ogol_resolve_state_change__(from_state, transition, staging),
               :ok <- __ogol_validate_reply_cardinality__(delivered, state_after_commit.staging),
               :ok <-
                 Ogol.Runtime.Safety.check!(
                   __MODULE__,
                   __ogol_machine__().safety_rules,
                   state_after_commit.state_name,
                   state_after_commit.staging.data
                 ),
               {:ok, committed_data} <-
                 __ogol_commit_boundary_effects__(
                   state_after_commit.staging.data,
                   state_after_commit.staging.boundary_effects
                 ) do
            if state_after_commit.entered? do
              __ogol_notify_state_entered__(committed_data, state_after_commit.state_name)
            end

            __ogol_build_transition_result__(from_state, state_after_commit, committed_data)
          else
            {:error, reason} ->
              {:stop, reason}
          end
        rescue
          error in Ogol.Runtime.SafetyViolation ->
            {:stop, {:safety_violation, error.check, error.state}}
        end
      end

      defp __ogol_resolve_state_change__(from_state, transition, staging) do
        cond do
          transition.destination == from_state and not transition.reenter? ->
            {:ok, %{state_name: from_state, staging: staging, entered?: false}}

          true ->
            case __ogol_stage_state_entry__(transition.destination, staging) do
              {:ok, next_staging} ->
                {:ok,
                 %{
                   state_name: transition.destination,
                   staging: next_staging,
                   entered?: true
                 }}

              {:error, reason} ->
                {:error, reason}
            end
        end
      end

      defp __ogol_validate_reply_cardinality__(%Ogol.Runtime.DeliveredEvent{family: :request}, %{
             reply_count: count
           })
           when count > 1 do
        {:error, {:invalid_reply_cardinality, count}}
      end

      defp __ogol_validate_reply_cardinality__(%Ogol.Runtime.DeliveredEvent{family: :request}, %{
             reply_count: 0,
             stop_reason: nil
           }) do
        {:error, {:missing_reply}}
      end

      defp __ogol_validate_reply_cardinality__(
             %Ogol.Runtime.DeliveredEvent{family: :request},
             _staging
           ),
           do: :ok

      defp __ogol_validate_reply_cardinality__(nil, %{reply_count: 0}), do: :ok

      defp __ogol_validate_reply_cardinality__(nil, %{reply_count: count}) when count > 0,
        do: {:error, {:reply_outside_request, count}}

      defp __ogol_validate_reply_cardinality__(_delivered, %{reply_count: 0}), do: :ok

      defp __ogol_validate_reply_cardinality__(_delivered, %{reply_count: count}),
        do: {:error, {:invalid_reply_cardinality, count}}

      defp __ogol_default_unmatched__(
             state_name,
             %Ogol.Runtime.DeliveredEvent{family: :request, from: from},
             data
           ) do
        :ok =
          Ogol.Runtime.Safety.check!(
            __MODULE__,
            __ogol_machine__().safety_rules,
            state_name,
            data
          )

        {:keep_state, data, [{:reply, from, {:error, :unhandled_request}}]}
      rescue
        error in Ogol.Runtime.SafetyViolation ->
          {:stop, {:safety_violation, error.check, error.state}}
      end

      defp __ogol_default_unmatched__(state_name, _delivered, data) do
        :ok =
          Ogol.Runtime.Safety.check!(
            __MODULE__,
            __ogol_machine__().safety_rules,
            state_name,
            data
          )

        {:keep_state, data}
      rescue
        error in Ogol.Runtime.SafetyViolation ->
          {:stop, {:safety_violation, error.check, error.state}}
      end

      defp __ogol_commit_boundary_effects__(data, effects) do
        Enum.reduce_while(effects, {:ok, data}, fn effect, {:ok, current_data} ->
          case __ogol_commit_boundary_effect__(current_data, effect) do
            {:ok, next_data} -> {:cont, {:ok, next_data}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end

      defp __ogol_commit_boundary_effect__(
             data,
             {:output, %{name: name, value: value}}
           ) do
        __ogol_write_io_output__(data, name, value, %{})
      end

      defp __ogol_commit_boundary_effect__(
             data,
             {:signal, %{name: name, data: signal_data, meta: meta}}
           ) do
        if sink = data.meta.signal_sink do
          send(sink, {:ogol_signal, data.machine_id, name, signal_data, meta})
        end

        Ogol.Machine.Registry.broadcast_signal(data.machine_id, name, signal_data, meta)

        Ogol.Runtime.Notifier.emit(:signal_emitted,
          machine_id: data.machine_id,
          source: __MODULE__,
          payload: %{name: name, data: signal_data, meta: meta},
          meta: %{pid: self()}
        )

        {:ok, data}
      end

      defp __ogol_commit_boundary_effect__(
             data,
             {:command, %{name: name, data: command_data, meta: meta}}
           ) do
        case data.io_adapter.dispatch(
               __MODULE__,
               data.io_binding,
               name,
               command_data,
               meta
             ) do
          :ok ->
            Ogol.Runtime.Notifier.emit(:command_dispatched,
              machine_id: data.machine_id,
              source: __MODULE__,
              payload: %{name: name, data: command_data, meta: meta},
              meta: %{pid: self()}
            )

            {:ok, data}

          {:error, reason} ->
            Ogol.Runtime.Notifier.emit(:command_failed,
              machine_id: data.machine_id,
              source: __MODULE__,
              payload: %{name: name, data: command_data, meta: meta, reason: reason},
              meta: %{pid: self()}
            )

            {:error, {:hardware_dispatch_failed, reason}}
        end
      end

      defp __ogol_commit_boundary_effect__(
             data,
             {:state_timeout, %{name: name, delay_ms: delay_ms, data: event_data, meta: meta}}
           ) do
        timeout_refs = Map.get(data.meta, :timeout_refs, %{})

        if old_ref = timeout_refs[name] do
          Process.cancel_timer(old_ref)
        end

        ref = Process.send_after(self(), {:ogol_state_timeout, name, event_data, meta}, delay_ms)
        {:ok, put_in(data.meta.timeout_refs[name], ref)}
      end

      defp __ogol_commit_boundary_effect__(data, {:cancel_timeout, %{name: name}}) do
        timeout_refs = Map.get(data.meta, :timeout_refs, %{})

        if ref = timeout_refs[name] do
          Process.cancel_timer(ref)
        end

        {:ok, update_in(data.meta.timeout_refs, &Map.delete(&1, name))}
      end

      defp __ogol_build_transition_result__(
             from_state,
             %{state_name: to_state, staging: staging},
             data
           ) do
        case staging.stop_reason do
          nil ->
            __ogol_state_result__(from_state, to_state, data, staging.otp_actions)

          reason ->
            __ogol_stop_result__(reason, data, staging.otp_actions)
        end
      end

      defp __ogol_state_result__(from_state, to_state, data, otp_actions)
           when from_state == to_state do
        case otp_actions do
          [] -> {:keep_state, data}
          _ -> {:keep_state, data, otp_actions}
        end
      end

      defp __ogol_state_result__(_from_state, to_state, data, otp_actions) do
        {:next_state, to_state, data, otp_actions}
      end

      defp __ogol_stop_result__(reason, data, otp_actions) do
        {replies, other_actions} =
          Enum.split_with(otp_actions, fn
            {:reply, _, _} -> true
            _ -> false
          end)

        case other_actions do
          [] ->
            case replies do
              [] -> {:stop, reason, data}
              _ -> {:stop_and_reply, reason, replies, data}
            end

          _ ->
            {:stop, {:invalid_stop_actions, other_actions}, data}
        end
      end

      defp __ogol_notify_machine_started__(data) do
        Ogol.Runtime.Notifier.emit(:machine_started,
          machine_id: data.machine_id,
          topology_id: data.meta.topology_id,
          source: __MODULE__,
          payload: %{module: __MODULE__},
          meta: %{pid: self()}
        )

        :ok
      end

      defp __ogol_notify_state_entered__(data, state_name) do
        Ogol.Runtime.Notifier.emit(:state_entered,
          machine_id: data.machine_id,
          topology_id: data.meta.topology_id,
          source: __MODULE__,
          payload: %{module: __MODULE__, state: state_name},
          meta: %{pid: self()}
        )

        :ok
      end

      defp __ogol_public_status_values__(data) do
        Ogol.Machine.Status.public_values(
          __ogol_contract__(),
          data.facts,
          data.outputs,
          data.fields
        )
      end

      defp __ogol_notify_terminated__(data, reason) do
        type =
          case reason do
            :normal -> :machine_stopped
            :shutdown -> :machine_stopped
            {:shutdown, _} -> :machine_stopped
            _ -> :machine_down
          end

        Ogol.Runtime.Notifier.emit(type,
          machine_id: data.machine_id,
          topology_id: data.meta.topology_id,
          source: __MODULE__,
          payload: %{module: __MODULE__, reason: reason},
          meta: %{pid: self()}
        )

        :ok
      end

      defp __ogol_maybe_notify_delivered__(data, %Ogol.Runtime.DeliveredEvent{
             family: :hardware,
             data: event_data,
             meta: meta
           }) do
        Ogol.Runtime.Notifier.emit(:adapter_feedback,
          machine_id: data.machine_id,
          topology_id: data.meta.topology_id,
          source: __MODULE__,
          payload: event_data,
          meta: Map.merge(%{pid: self()}, meta)
        )
      end

      defp __ogol_maybe_notify_delivered__(_data, _delivered), do: :ok

      defp __ogol_attach_io__(data) do
        adapter = data.io_adapter

        cond do
          Code.ensure_loaded?(adapter) and function_exported?(adapter, :attach, 3) ->
            case adapter.attach(__MODULE__, self(), data.io_binding) do
              :ok -> :ok
              {:error, reason} -> {:error, {:hardware_attach_failed, reason}}
            end

          true ->
            :ok
        end
      end

      defp __ogol_write_io_output__(data, name, value, meta) do
        adapter = data.io_adapter

        cond do
          Code.ensure_loaded?(adapter) and function_exported?(adapter, :write_output, 5) ->
            case adapter.write_output(__MODULE__, data.io_binding, name, value, meta) do
              :ok -> {:ok, data}
              {:error, reason} -> {:error, {:hardware_output_failed, reason}}
            end

          true ->
            {:ok, data}
        end
      end
    end
  end
end
