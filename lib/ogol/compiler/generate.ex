defmodule Ogol.Compiler.Generate do
  @moduledoc false

  defmacro inject do
    parent_module = __CALLER__.module

    quote generated: true do
      @ogol_machine Ogol.Compiler.Normalize.from_dsl!(@spark_dsl_config, __MODULE__)

      @behaviour :gen_statem

      def __ogol_machine__, do: @ogol_machine

      def start_link(opts \\ []), do: :gen_statem.start_link(__MODULE__, opts, [])
      def start(opts \\ []), do: :gen_statem.start(__MODULE__, opts, [])

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

      def terminate(_reason, _state, _data), do: :ok

      def code_change(_old_vsn, state, data, _extra), do: {:ok, state, data}

      defmodule Topology do
        @moduledoc false

        use GenServer

        @parent_module unquote(parent_module)

        def start_link(opts \\ []) do
          GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def start(opts \\ []) do
          GenServer.start(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def child_spec(opts) do
          %{
            id: __MODULE__,
            start: {__MODULE__, :start_link, [opts]}
          }
        end

        def request(server, name, data \\ %{}, meta \\ %{}, timeout \\ 5_000) do
          GenServer.call(server, {:request, name, data, meta, timeout}, timeout + 100)
        end

        def event(server, name, data \\ %{}, meta \\ %{}) do
          GenServer.call(server, {:event, name, data, meta})
        end

        def child_pid(server, child_name) do
          GenServer.call(server, {:child_pid, child_name})
        end

        def brain_pid(server) do
          GenServer.call(server, :brain_pid)
        end

        @impl true
        def init(opts) do
          machine = @parent_module.__ogol_machine__()

          {:ok, router} =
            Ogol.Topology.Router.start_link(
              parent_machine_id: machine.name,
              children: machine.children
            )

          {:ok, supervisor} =
            Supervisor.start_link(build_child_specs(machine, router, opts),
              strategy: :one_for_one
            )

          :ok = Ogol.Topology.Router.await_ready(router)
          parent_pid = Ogol.Topology.Router.parent_pid(router)

          {:ok, %{router: router, supervisor: supervisor, parent_pid: parent_pid}}
        end

        @impl true
        def handle_call({:request, name, data, meta, timeout}, _from, state) do
          reply =
            try do
              Ogol.request(state.parent_pid, name, data, meta, timeout)
            catch
              :exit, reason -> {:error, {:target_exit, reason}}
            end

          {:reply, reply, state}
        end

        def handle_call({:event, name, data, meta}, _from, state) do
          {:reply, Ogol.event(state.parent_pid, name, data, meta), state}
        end

        def handle_call({:child_pid, child_name}, _from, state) do
          {:reply, Ogol.Topology.Router.child_pid(state.router, child_name), state}
        end

        def handle_call(:brain_pid, _from, state) do
          {:reply, state.parent_pid, state}
        end

        defp build_child_specs(machine, router, opts) do
          signal_sink = Keyword.get(opts, :signal_sink)
          child_overrides = Keyword.get(opts, :child_opts, %{})

          brain_opts =
            opts
            |> Keyword.drop([:name, :child_opts])
            |> Keyword.put(:machine_id, machine.name)
            |> Keyword.put(:signal_sink, signal_sink)
            |> Keyword.put(:topology_router, router)

          brain_spec =
            Supervisor.child_spec({@parent_module, brain_opts},
              id: :ogol_brain,
              restart: :permanent
            )

          child_specs =
            Enum.map(machine.children, fn child ->
              override_opts = Map.get(child_overrides, child.name, [])

              child_opts =
                child.opts
                |> Keyword.merge(override_opts)
                |> Keyword.put(:machine_id, child.name)
                |> Keyword.put(:signal_sink, router)
                |> Keyword.put(:topology_router, router)

              Supervisor.child_spec({child.machine, child_opts},
                id: {:ogol_child, child.name},
                restart: child.restart || :permanent
              )
            end)

          [brain_spec | child_specs]
        end
      end
    end
  end
end
