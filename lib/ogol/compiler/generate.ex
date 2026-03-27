defmodule Ogol.Compiler.Generate do
  @moduledoc false

  defmacro inject do
    quote generated: true do
      @ogol_machine Ogol.Compiler.Normalize.from_dsl!(@spark_dsl_config, __MODULE__)
      @ogol_interface Ogol.Compiler.Interface.from_dsl!(
                        @spark_dsl_config,
                        @ogol_machine,
                        __MODULE__
                      )

      @behaviour :gen_statem

      def __ogol_machine__, do: @ogol_machine
      def __ogol_interface__, do: @ogol_interface

      def start_link(opts \\ []) do
        case Keyword.get(opts, :name) do
          nil -> :gen_statem.start_link(__MODULE__, opts, [])
          name -> :gen_statem.start_link(name, __MODULE__, opts, [])
        end
      end

      def start(opts \\ []) do
        case Keyword.get(opts, :name) do
          nil -> :gen_statem.start(__MODULE__, opts, [])
          name -> :gen_statem.start(name, __MODULE__, opts, [])
        end
      end

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]}
        }
      end

      def callback_mode, do: :state_functions

      def init(opts) do
        machine = __ogol_machine__()
        data = __ogol_init_data__(machine, opts)
        Process.flag(:trap_exit, true)

        with :ok <- __ogol_attach_hardware__(data),
             {:ok, staging} <-
               __ogol_stage_state_entry__(
                 machine.initial_state,
                 %Ogol.Runtime.Staging{data: data}
               ),
             :ok <- __ogol_validate_reply_cardinality__(nil, staging),
             :ok <-
               Ogol.Runtime.Safety.check!(
                 __MODULE__,
                 machine.safety_rules,
                 machine.initial_state,
                 staging.data
               ),
             {:ok, committed_data} <-
               __ogol_commit_boundary_effects__(staging.data, staging.boundary_effects) do
          __ogol_notify_state_entered__(committed_data, machine.initial_state)
          __ogol_notify_machine_started__(committed_data)

          case staging.stop_reason do
            nil ->
              {:ok, machine.initial_state, committed_data, staging.otp_actions}

            reason ->
              {:stop, reason}
          end
        else
          {:error, reason} -> {:stop, reason}
          {:stop, reason} -> {:stop, reason}
        end
      rescue
        error in Ogol.Runtime.SafetyViolation ->
          {:stop, {:safety_violation, error.check, error.state}}
      end

      def terminate(reason, _state, data) do
        __ogol_notify_terminated__(data, reason)
        :ok
      end

      def code_change(_old_vsn, state, data, _extra), do: {:ok, state, data}
    end
  end
end
