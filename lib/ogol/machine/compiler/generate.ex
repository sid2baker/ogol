defmodule Ogol.Machine.Compiler.Generate do
  @moduledoc false

  defmacro inject do
    quote generated: true do
      @ogol_machine Ogol.Machine.Compiler.Normalize.from_dsl!(@spark_dsl_config, __MODULE__)
      @ogol_interface Ogol.Machine.Compiler.Interface.from_dsl!(
                        @spark_dsl_config,
                        @ogol_machine,
                        __MODULE__
                      )

      @behaviour :gen_statem
      @before_compile Ogol.Machine.Compiler.Generate

      def __ogol_machine__, do: @ogol_machine
      def __ogol_interface__, do: @ogol_interface

      @doc """
      Returns the list of public skills for this machine.
      """
      @spec skills() :: [Ogol.Machine.Skill.t()]
      def skills, do: Enum.filter(@ogol_interface.skills, & &1.visible?)

      @doc """
      Returns the list of declared signals for this machine.
      """
      def signals, do: @ogol_interface.signals

      @doc """
      Looks up a machine pid by its machine_id in the registry.
      """
      @spec whereis(atom()) :: pid() | nil
      def whereis(machine_id), do: Ogol.Machine.Registry.whereis(machine_id)

      @doc """
      Returns a status projection for the given machine target.

      Reads the machine's current state directly from the process via `:sys.get_state/1`.
      """
      @spec status(pid() | atom()) :: Ogol.Status.t() | nil
      def status(target) do
        interface = @ogol_interface

        case Ogol.Runtime.Target.resolve_machine_runtime(target) do
          {:ok, %{state_name: state_name, data: %Ogol.Runtime.Data{} = data}} ->
            %Ogol.Status{
              machine_id: data.machine_id,
              module: __MODULE__,
              current_state: state_name,
              health: __ogol_infer_health__(state_name),
              connected?: true,
              facts: __ogol_pick_public__(data.facts, interface.status_spec.facts),
              outputs: __ogol_pick_public__(data.outputs, interface.status_spec.outputs),
              fields: __ogol_pick_public__(data.fields, interface.status_spec.fields)
            }

          {:error, _reason} ->
            nil
        end
      end

      defp __ogol_infer_health__(state) when state in [:running], do: :running
      defp __ogol_infer_health__(state) when state in [:idle, :waiting], do: :waiting
      defp __ogol_infer_health__(state) when state in [:fault, :faulted], do: :faulted
      defp __ogol_infer_health__(_state), do: :healthy

      defp __ogol_pick_public__(values, _spec_items) when values == %{}, do: %{}

      defp __ogol_pick_public__(values, spec_items) when is_map(values) do
        spec_items
        |> Enum.flat_map(fn %{name: name} ->
          case Map.fetch(values, name) do
            {:ok, value} -> [{name, value}]
            :error -> []
          end
        end)
        |> Map.new()
      end

      @doc """
      Subscribe to a specific signal from a machine instance.

      The subscriber process will receive messages of the form:
      `{:ogol_signal, machine_id, signal_name, data, meta}`
      """
      def subscribe_signal(target, signal_name) do
        machine_id = __resolve_machine_id__(target)
        Ogol.Machine.Registry.subscribe_signal(machine_id, signal_name)
      end

      @doc """
      Subscribe to all signals from a machine instance.

      The subscriber process will receive messages of the form:
      `{:ogol_signal, machine_id, signal_name, data, meta}`
      """
      def subscribe_signals(target) do
        machine_id = __resolve_machine_id__(target)
        Ogol.Machine.Registry.subscribe_signals(machine_id)
      end

      defp __resolve_machine_id__(machine_id) when is_atom(machine_id), do: machine_id

      defp __resolve_machine_id__(pid) when is_pid(pid) do
        case Ogol.Runtime.Target.machine_id(pid) do
          {:ok, machine_id} -> machine_id
          {:error, _reason} -> raise ArgumentError, "pid #{inspect(pid)} not found in runtime"
        end
      end

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

        with :ok <- __ogol_register_machine__(data),
             :ok <- __ogol_attach_hardware__(data),
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

      defp __ogol_register_machine__(%Ogol.Runtime.Data{machine_id: machine_id}) do
        Ogol.Machine.Registry.register_instance(machine_id, __MODULE__)
      end
    end
  end

  defmacro __before_compile__(env) do
    interface = Module.get_attribute(env.module, :ogol_interface)

    skill_fns =
      Enum.map(interface.skills, fn
        %Ogol.Machine.Skill{name: name, kind: :request} ->
          quote generated: true do
            @doc "Invoke skill `#{unquote(name)}` (request-backed, synchronous)."
            def unquote(name)(target, args \\ %{}, opts \\ []) do
              pid = Ogol.Runtime.Target.resolve_machine_pid!(target)
              meta = Keyword.get(opts, :meta, %{})
              timeout = Keyword.get(opts, :timeout, 5_000)
              :gen_statem.call(pid, {:request, unquote(name), args, meta}, timeout)
            end
          end

        %Ogol.Machine.Skill{name: name, kind: :event} ->
          quote generated: true do
            @doc "Invoke skill `#{unquote(name)}` (event-backed, asynchronous)."
            def unquote(name)(target, args \\ %{}, opts \\ []) do
              pid = Ogol.Runtime.Target.resolve_machine_pid!(target)
              meta = Keyword.get(opts, :meta, %{})
              :gen_statem.cast(pid, {:event, unquote(name), args, meta})
              :ok
            end
          end
      end)

    quote generated: true do
      (unquote_splicing(skill_fns))
    end
  end
end
