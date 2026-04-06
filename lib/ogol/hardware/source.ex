defmodule Ogol.Hardware.Source do
  @moduledoc false

  alias Elixir.EtherCAT.Slave.Config, as: SlaveConfig
  alias Ogol.Hardware
  alias Ogol.Hardware.EtherCAT
  alias Ogol.Hardware.EtherCAT.{Domain, Timing, Transport}

  @ethercat_module Ogol.Generated.Hardware.EtherCAT

  @type hardware_t :: Hardware.t()

  @spec canonical_module() :: module()
  def canonical_module, do: @ethercat_module

  @spec canonical_module(Hardware.adapter_t() | hardware_t()) :: module()
  def canonical_module(:ethercat), do: @ethercat_module
  def canonical_module(%EtherCAT{}), do: @ethercat_module

  @spec default_model(String.t() | atom()) :: hardware_t() | nil
  def default_model("ethercat"), do: EtherCAT.default()
  def default_model(:ethercat), do: EtherCAT.default()
  def default_model(_other), do: nil

  @spec default_source(String.t() | atom()) :: String.t()
  def default_source(id) do
    case default_model(id) do
      %EtherCAT{} = hardware -> to_source(hardware)
      nil -> ""
    end
  end

  @spec module_from_source(String.t()) :: {:ok, module()} | {:error, :module_not_found}
  def module_from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, module} <- extract_module(ast) do
      {:ok, module}
    else
      _ -> {:error, :module_not_found}
    end
  end

  @spec to_source(hardware_t()) :: String.t()
  def to_source(%EtherCAT{} = hardware), do: to_source(hardware, canonical_module(hardware))

  @spec to_source(hardware_t(), module()) :: String.t()
  def to_source(%EtherCAT{} = hardware, module) when is_atom(module) do
    hardware
    |> to_source_string(module)
    |> Code.format_string!()
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  @spec from_source(String.t()) :: {:ok, hardware_t()} | :unsupported
  def from_source(source) when is_binary(source) do
    with {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true),
         {:ok, definition_term} <- extract_hardware_term(ast),
         {:ok, hardware} <- hardware_from_term(definition_term) do
      {:ok, hardware}
    else
      _ -> :unsupported
    end
  end

  defp to_source_string(%EtherCAT{} = hardware, module) do
    definition =
      hardware
      |> hardware_literal()
      |> inspect(pretty: true, limit: :infinity)

    """
    defmodule #{inspect(module)} do
      @moduledoc false

      use Ogol.Hardware

      alias EtherCAT.Backend
      alias EtherCAT.Event
      alias EtherCAT.Master
      alias EtherCAT.Master.Status, as: MasterStatus
      alias EtherCAT.Simulator
      alias EtherCAT.Simulator.Status, as: SimulatorStatus
      alias EtherCAT.Slave.Config, as: SlaveConfig
      alias Ogol.Runtime.DeliveredEvent
      alias Ogol.Topology.Wiring

      @default_id "ethercat"
      @default_label "EtherCAT"
      @await_timeout 2_000
      @default_simulator_host {127, 0, 0, 2}
      @allowed_binding_keys [:slave, :outputs, :facts, :commands, :event_name, :meta]
      @hardware #{definition}

      @impl true
      def hardware, do: @hardware

      @impl true
      def id do
        case @hardware.id do
          id when is_binary(id) and id != "" -> id
          _other -> @default_id
        end
      end

      @impl true
      def label do
        case @hardware.label do
          label when is_binary(label) and label != "" -> label
          _other -> @default_label
        end
      end

      @impl true
      def child_specs(_opts \\\\ []) do
        hardware_id = id()

        {:ok,
         [
           Supervisor.child_spec({EtherCAT.Runtime, []},
             id: {:ogol_hardware_runtime, hardware_id},
             type: :supervisor
           ),
           Supervisor.child_spec(%{
             id: {:ogol_hardware_session, hardware_id},
             start: {__MODULE__, :start_session_link, [@hardware]}
           },
             id: {:ogol_hardware_session, hardware_id}
           )
         ]}
      end

      def start_session_link(%Ogol.Hardware.EtherCAT{} = hardware) do
        GenServer.start_link(__MODULE__, {:runtime_session, hardware})
      end

      @impl GenServer
      def init({:runtime_session, %Ogol.Hardware.EtherCAT{} = hardware}) do
        Process.flag(:trap_exit, true)

        with {:ok, runtime} <- start_master(hardware) do
          {:ok,
           %{
             hardware: hardware,
             master_pid: runtime.master_pid,
             master_ref: Process.monitor(runtime.master_pid)
           }}
        else
          {:error, reason} ->
            {:stop, {:hardware_activation_failed, reason}}
        end
      end

      @impl GenServer
      def handle_info({:DOWN, ref, :process, _pid, reason}, %{master_ref: ref} = state) do
        {:stop, {:hardware_runtime_down, reason}, state}
      end

      def handle_info(_message, state), do: {:noreply, state}

      @impl GenServer
      def terminate(_reason, %{hardware: _hardware}) do
        _ = stop_master()
        :ok
      end

      def terminate(_reason, _state), do: :ok

      def start_master(%Ogol.Hardware.EtherCAT{} = spec) do
        with {:ok, backend} <- master_backend(spec),
             :ok <- EtherCAT.start(master_start_opts(spec, backend)),
             :ok <- EtherCAT.await_running(@await_timeout),
             %MasterStatus{} = status <- Master.status(),
             pid when is_pid(pid) <- Process.whereis(EtherCAT.Master) do
          {:ok,
           %{
             config: spec,
             slaves: Enum.map(spec.slaves, & &1.name),
             master_pid: pid,
             backend: backend,
             port: backend_port(backend),
             state: status.lifecycle
           }}
        else
          nil ->
            {:error, :master_not_running}

          {:error, _reason} = error ->
            error

          other ->
            {:error, {:invalid_master_status, other}}
        end
      end

      def stop_master do
        case EtherCAT.stop() do
          :ok -> :ok
          {:error, :already_stopped} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

      @impl true
      def bind(%Wiring{} = wiring) do
        if Wiring.empty?(wiring) do
          {:ok, nil}
        else
          resolve_wiring(wiring, @hardware.slaves)
        end
      end

      @impl true
      def normalize_message(bindings, message) do
        case normalize_runtime_bindings(bindings) do
          {:ok, normalized} -> do_normalize_message(normalized, message)
          {:error, _reason} -> nil
        end
      end

      @impl true
      def attach(_machine, server, bindings) do
        with {:ok, normalized} <- normalize_runtime_bindings(bindings) do
          do_attach(server, normalized)
        end
      end

      @impl true
      def dispatch_command(_machine, bindings, command, data, meta) do
        with {:ok, normalized} <- normalize_runtime_bindings(bindings) do
          do_dispatch_command(normalized, command, data, meta)
        end
      end

      @impl true
      def write_output(_machine, bindings, output, value, meta) do
        with {:ok, normalized} <- normalize_runtime_bindings(bindings) do
          do_write_output(normalized, output, value, meta)
        end
      end

      defp do_attach(server, bindings) when is_list(bindings) do
        Enum.reduce_while(bindings, :ok, fn binding, :ok ->
          case do_attach(server, binding) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end

      defp do_attach(server, %{slave: slave} = binding) do
        if binding_observes_anything?(binding) do
          EtherCAT.subscribe(slave, server)
        else
          :ok
        end
      end

      defp do_attach(_server, binding), do: {:error, {:invalid_ethercat_binding, binding}}

      defp do_dispatch_command(bindings, command, data, meta) when is_list(bindings) do
        with {:ok, binding} <- select_dispatch_binding(bindings, command) do
          do_dispatch_command(binding, command, data, meta)
        end
      end

      defp do_dispatch_command(%{slave: _slave} = binding, command, data, _meta) do
        binding
        |> resolve_command(command, data)
        |> dispatch_operation(binding)
      end

      defp do_dispatch_command(binding, _command, _data, _meta),
        do: {:error, {:invalid_ethercat_binding, binding}}

      defp do_write_output(bindings, output, value, meta) when is_list(bindings) do
        with {:ok, binding} <- select_output_binding(bindings, output) do
          do_write_output(binding, output, value, meta)
        end
      end

      defp do_write_output(%{slave: slave} = binding, output, value, _meta) do
        case binding_output_endpoint(binding, output) do
          signal when is_atom(signal) ->
            case EtherCAT.command(slave, :set_output, %{signal: signal, value: value}) do
              {:ok, _reference} -> :ok
              {:error, reason} -> {:error, reason}
            end

          nil ->
            {:error, {:unmapped_ethercat_output, output}}
        end
      end

      defp do_write_output(binding, _output, _value, _meta),
        do: {:error, {:invalid_ethercat_binding, binding}}

      defp do_normalize_message(bindings, message) when is_list(bindings) do
        Enum.find_value(bindings, &do_normalize_message(&1, message))
      end

      defp do_normalize_message(
             %{slave: binding_slave} = binding,
             %Event{
               kind: :signal_changed,
               slave: slave,
               signal: {_slave, signal},
               value: value,
               cycle: cycle,
               updated_at_us: updated_at_us
             }
           ) do
        if slave == binding_slave and binding_observes_fact?(binding, signal) do
          delivered_from_signal(binding, signal, value, %{
            slave: slave,
            signal: signal,
            cycle: cycle,
            updated_at_us: updated_at_us,
            source: :runtime
          })
        end
      end

      defp do_normalize_message(
             %{slave: binding_slave} = binding,
             %Event{
               slave: slave,
               kind: kind,
               data: data,
               cycle: cycle,
               updated_at_us: updated_at_us
             }
           ) do
        if slave == binding_slave and binding_observes_events?(binding) do
          %DeliveredEvent{
            family: :hardware,
            name: binding_event_name(binding),
            data: %{event: data},
            meta:
              binding.meta
              |> Map.merge(%{
                bus: :ethercat,
                slave: slave,
                kind: kind,
                cycle: cycle,
                updated_at_us: updated_at_us,
                source: :runtime
              })
          }
        end
      end

      defp do_normalize_message(_binding, _message), do: nil

      defp resolve_wiring(%Wiring{} = wiring, slaves) when is_list(slaves) do
        slave_index = build_slave_index(slaves)

        with {:ok, output_groups} <- resolve_output_groups(wiring.outputs, slave_index),
             {:ok, fact_groups} <- resolve_fact_groups(wiring.facts, slave_index),
             {:ok, command_groups} <- resolve_command_groups(wiring.commands, slave_index) do
          bindings =
            output_groups
            |> Map.merge(fact_groups, fn _slave, left, right -> Map.merge(left, right) end)
            |> Map.merge(command_groups, fn _slave, left, right -> Map.merge(left, right) end)
            |> Enum.map(fn {slave, attrs} -> new_binding(slave, attrs, wiring.event_name) end)
            |> Enum.sort_by(& &1.slave)

          {:ok, bindings}
        end
      end

      defp new_binding(slave, attrs, event_name) do
        %{
          slave: slave,
          outputs: Map.get(attrs, :outputs, %{}),
          facts: Map.get(attrs, :facts, %{}),
          commands: Map.get(attrs, :commands, %{}),
          event_name: event_name,
          meta: %{}
        }
      end

      defp build_slave_index(slaves) do
        Enum.reduce(slaves, %{}, fn
          %SlaveConfig{name: slave_name} = slave, acc when is_atom(slave_name) ->
            Map.put(acc, slave_name, %{
              signals: signal_directions(slave),
              commands: supported_commands(slave)
            })

          _slave, acc ->
            acc
        end)
      end

      defp resolve_output_groups(outputs, slave_index) do
        Enum.reduce_while(outputs, {:ok, %{}}, fn {port, ref}, {:ok, acc} ->
          with {:ok, {slave, signal}} <- resolve_signal_ref(ref, slave_index, :output) do
            next_acc =
              update_in(
                acc,
                [Access.key(slave, %{}), Access.key(:outputs, %{})],
                &Map.put(&1, port, signal)
              )

            {:cont, {:ok, next_acc}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end

      defp resolve_fact_groups(facts, slave_index) do
        Enum.reduce_while(facts, {:ok, %{}}, fn {port, ref}, {:ok, acc} ->
          with {:ok, {slave, signal}} <- resolve_signal_ref(ref, slave_index, :input) do
            next_acc =
              update_in(
                acc,
                [Access.key(slave, %{}), Access.key(:facts, %{})],
                &Map.put(&1, port, signal)
              )

            {:cont, {:ok, next_acc}}
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end

      defp resolve_command_groups(commands, slave_index) do
        Enum.reduce_while(commands, {:ok, %{}}, fn
          {name, {slave, command, args}}, {:ok, acc} ->
            with {:ok, normalized_args} <- normalize_command_args(args),
                 {:ok, slave_info} <- fetch_slave_info(slave_index, slave, {:command, name}),
                 :ok <- ensure_command_supported(slave_info, command, name) do
              next_acc =
                update_in(
                  acc,
                  [Access.key(slave, %{}), Access.key(:commands, %{})],
                  &Map.put(&1, name, {:command, command, normalized_args})
                )

              {:cont, {:ok, next_acc}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {name, ref}, {:ok, _acc} ->
            {:halt, {:error, {:invalid_hardware_command_ref, name, ref}}}
        end)
      end

      defp resolve_signal_ref({slave, signal}, slave_index, required_direction)
           when is_atom(slave) and is_atom(signal) do
        with {:ok, slave_info} <- fetch_slave_info(slave_index, slave, {required_direction, signal}),
             :ok <- ensure_signal_supported(slave_info, signal, required_direction, slave) do
          {:ok, {slave, signal}}
        end
      end

      defp resolve_signal_ref(ref, _slave_index, context),
        do: {:error, {:invalid_hardware_signal_ref, ref, context}}

      defp fetch_slave_info(slave_index, slave, context) do
        case Map.fetch(slave_index, slave) do
          {:ok, info} -> {:ok, info}
          :error -> {:error, {:unknown_hardware_slave, slave, context}}
        end
      end

      defp ensure_signal_supported(slave_info, signal, required_direction, slave) do
        case Map.fetch(slave_info.signals, signal) do
          {:ok, direction} ->
            if direction in [required_direction, :unknown] do
              :ok
            else
              {:error,
               {:invalid_hardware_signal_direction, slave, signal, required_direction, direction}}
            end

          :error ->
            {:error, {:unknown_hardware_signal, slave, signal}}
        end
      end

      defp ensure_command_supported(slave_info, command, binding_name) do
        if MapSet.member?(slave_info.commands, command) do
          :ok
        else
          {:error, {:unsupported_hardware_command, binding_name, command}}
        end
      end

      defp normalize_command_args(args) when is_map(args), do: {:ok, args}

      defp normalize_command_args(args) when is_list(args) do
        if Keyword.keyword?(args) do
          {:ok, Map.new(args)}
        else
          {:error, {:invalid_hardware_command_args, args}}
        end
      end

      defp normalize_command_args(args), do: {:error, {:invalid_hardware_command_args, args}}

      defp signal_directions(%SlaveConfig{} = slave) do
        describe_slave(slave)
        |> Map.get(:endpoints, [])
        |> Enum.reduce(signal_model_directions(slave), fn endpoint, acc ->
          case normalize_endpoint(endpoint) do
            {:ok, signal, direction} -> Map.put(acc, signal, direction)
            :error -> acc
          end
        end)
      end

      defp signal_model_directions(%SlaveConfig{driver: driver}) when is_atom(driver) do
        if Code.ensure_loaded?(driver) and function_exported?(driver, :signal_model, 2) do
          driver
          |> apply(:signal_model, [%{}, []])
          |> Keyword.keys()
          |> Map.new(&{&1, :unknown})
        else
          %{}
        end
      rescue
        _error -> %{}
      end

      defp supported_commands(%SlaveConfig{} = slave) do
        describe_slave(slave)
        |> Map.get(:commands, [])
        |> List.wrap()
        |> MapSet.new(fn
          command when is_atom(command) -> command
          %{name: name} when is_atom(name) -> name
        end)
      end

      defp describe_slave(%SlaveConfig{driver: driver} = slave) when is_atom(driver) do
        if Code.ensure_loaded?(driver) and function_exported?(driver, :describe, 1) do
          apply(driver, :describe, [Map.get(slave, :config, %{})])
        else
          %{}
        end
      rescue
        _error -> %{}
      end

      defp normalize_endpoint(%{signal: signal, direction: direction})
           when is_atom(signal) and direction in [:input, :output] do
        {:ok, signal, direction}
      end

      defp normalize_endpoint(%EtherCAT.Endpoint{signal: signal, direction: direction})
           when is_atom(signal) and direction in [:input, :output] do
        {:ok, signal, direction}
      end

      defp normalize_endpoint(_other), do: :error

      defp delivered_from_signal(%{meta: binding_meta} = binding, signal, value, meta) do
        fact_name = binding_machine_fact_for_endpoint(binding, signal) || signal

        %DeliveredEvent{
          family: :hardware,
          name: :process_image,
          data: %{
            signal: fact_name,
            channel: signal,
            value: value,
            facts: %{fact_name => value}
          },
          meta:
            binding_meta
            |> Map.merge(meta)
            |> Map.put(:bus, :ethercat)
            |> Map.put(:channel, signal)
        }
      end

      defp resolve_command(%{commands: commands} = _binding, command, data) do
        case Map.get(commands, command) do
          {:command, ethercat_command, args} when is_atom(ethercat_command) and is_map(args) ->
            {:ok, {:command, ethercat_command, Map.merge(args, data)}}

          nil ->
            {:ok, {:command, command, data}}

          other ->
            {:error, {:invalid_ethercat_command_mapping, command, other}}
        end
      end

      defp dispatch_operation({:ok, {:command, command, args}}, %{slave: slave}) do
        case EtherCAT.command(slave, command, args) do
          {:ok, _reference} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end

      defp dispatch_operation({:error, reason}, _binding), do: {:error, reason}

      defp select_dispatch_binding([], command),
        do: {:error, {:unmapped_ethercat_command, command}}

      defp select_dispatch_binding(bindings, command) do
        explicitly_mapped =
          Enum.filter(bindings, &binding_handles_command?(&1, command))

        case explicitly_mapped do
          [binding] ->
            {:ok, binding}

          [] ->
            case bindings do
              [%{slave: _slave} = binding] -> {:ok, binding}
              _ -> {:error, {:unmapped_ethercat_command, command}}
            end

          _ ->
            {:error, {:ambiguous_ethercat_command_mapping, command}}
        end
      end

      defp select_output_binding([], output), do: {:error, {:unmapped_ethercat_output, output}}

      defp select_output_binding(bindings, output) do
        mapped_refs =
          Enum.filter(bindings, &binding_handles_output?(&1, output))

        case mapped_refs do
          [binding] ->
            {:ok, binding}

          [] ->
            {:error, {:unmapped_ethercat_output, output}}

          _ ->
            {:error, {:ambiguous_ethercat_output_mapping, output}}
        end
      end

      defp normalize_runtime_bindings(refs) when is_list(refs) do
        if Keyword.keyword?(refs) do
          normalize_runtime_binding(refs)
        else
          normalize_runtime_binding_list(refs)
        end
      end

      defp normalize_runtime_bindings(ref), do: normalize_runtime_binding(ref)

      defp normalize_runtime_binding_list(refs) when is_list(refs) do
        Enum.reduce_while(refs, {:ok, []}, fn ref, {:ok, acc} ->
          case normalize_runtime_binding(ref) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
          {:error, reason} -> {:error, reason}
        end
      end

      defp normalize_runtime_binding_list(ref) do
        with {:ok, normalized} <- normalize_runtime_binding(ref) do
          {:ok, [normalized]}
        end
      end

      defp normalize_runtime_binding(binding) when is_list(binding) do
        if Keyword.keyword?(binding) do
          binding
          |> Map.new()
          |> normalize_runtime_binding()
        else
          {:error, {:invalid_ethercat_binding, binding}}
        end
      end

      defp normalize_runtime_binding(%{} = binding) do
        with :ok <- validate_binding_keys(binding),
             {:ok, slave} <- fetch_required_atom(binding, :slave),
             {:ok, outputs} <- normalize_binding_atom_map(binding, :outputs, %{}),
             {:ok, facts} <- normalize_binding_atom_map(binding, :facts, %{}),
             {:ok, commands} <- fetch_binding_commands(binding),
             {:ok, event_name} <- fetch_optional_atom(binding, :event_name),
             {:ok, meta} <- fetch_binding_meta(binding) do
          {:ok,
           %{
             slave: slave,
             outputs: outputs,
             facts: facts,
             commands: commands,
             event_name: event_name,
             meta: meta
           }}
        end
      end

      defp normalize_runtime_binding(binding),
        do: {:error, {:invalid_ethercat_binding, binding}}

      defp validate_binding_keys(binding) do
        case Map.keys(binding) -- @allowed_binding_keys do
          [] -> :ok
          unknown -> {:error, {:invalid_ethercat_binding_keys, unknown}}
        end
      end

      defp fetch_required_atom(binding, key) do
        case Map.fetch(binding, key) do
          {:ok, value} when is_atom(value) -> {:ok, value}
          {:ok, value} -> {:error, {:invalid_ethercat_binding_value, key, value}}
          :error -> {:error, {:missing_ethercat_binding_key, key}}
        end
      end

      defp fetch_optional_atom(binding, key) do
        case Map.get(binding, key) do
          nil -> {:ok, nil}
          value when is_atom(value) -> {:ok, value}
          value -> {:error, {:invalid_ethercat_binding_value, key, value}}
        end
      end

      defp normalize_binding_atom_map(binding, key, default) do
        value = Map.get(binding, key, default)

        cond do
          value == %{} or value == [] ->
            {:ok, %{}}

          is_list(value) and Keyword.keyword?(value) ->
            normalize_binding_atom_map(%{key => Map.new(value)}, key, default)

          is_map(value) and valid_atom_mapping?(value) ->
            {:ok, Map.new(value)}

          true ->
            {:error, {:invalid_ethercat_binding_value, key, value}}
        end
      end

      defp fetch_binding_commands(binding) do
        binding
        |> Map.get(:commands, %{})
        |> normalize_binding_commands()
      end

      defp normalize_binding_commands(commands) when commands == %{} or commands == [], do: {:ok, %{}}

      defp normalize_binding_commands(commands) when is_list(commands) do
        if Keyword.keyword?(commands) do
          commands
          |> Map.new()
          |> normalize_binding_commands()
        else
          {:error, {:invalid_ethercat_commands, commands}}
        end
      end

      defp normalize_binding_commands(commands) when is_map(commands) do
        Enum.reduce_while(commands, {:ok, %{}}, fn
          {name, {:command, command, args}}, {:ok, acc} when is_atom(name) and is_atom(command) ->
            with {:ok, normalized_args} <- normalize_command_args(args) do
              {:cont, {:ok, Map.put(acc, name, {:command, command, normalized_args})}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {name, binding}, _acc ->
            {:halt, {:error, {:invalid_ethercat_command_mapping, name, binding}}}
        end)
      end

      defp normalize_binding_commands(commands),
        do: {:error, {:invalid_ethercat_commands, commands}}

      defp fetch_binding_meta(binding) do
        case Map.get(binding, :meta, %{}) do
          meta when is_map(meta) -> {:ok, meta}
          value -> {:error, {:invalid_ethercat_binding_value, :meta, value}}
        end
      end

      defp valid_atom_mapping?(mapping) when is_map(mapping) do
        Enum.all?(mapping, fn {left, right} -> is_atom(left) and is_atom(right) end)
      end

      defp valid_atom_mapping?(_mapping), do: false

      defp binding_machine_fact_for_endpoint(%{facts: facts}, endpoint) when is_atom(endpoint) do
        Enum.find_value(facts, fn
          {fact, ^endpoint} -> fact
          _other -> nil
        end)
      end

      defp binding_machine_fact_for_endpoint(_binding, _endpoint), do: nil

      defp binding_output_endpoint(%{outputs: outputs}, output) when is_atom(output),
        do: Map.get(outputs, output)

      defp binding_output_endpoint(_binding, _output), do: nil

      defp binding_handles_output?(%{outputs: outputs}, output) when is_atom(output),
        do: Map.has_key?(outputs, output)

      defp binding_handles_output?(_binding, _output), do: false

      defp binding_handles_command?(%{commands: commands}, command) when is_atom(command),
        do: Map.has_key?(commands, command)

      defp binding_handles_command?(_binding, _command), do: false

      defp binding_observes_fact?(%{facts: facts}, endpoint) when is_atom(endpoint) do
        Enum.any?(facts, fn
          {_fact, ^endpoint} -> true
          _other -> false
        end)
      end

      defp binding_observes_fact?(_binding, _endpoint), do: false

      defp binding_event_name(%{event_name: event_name}), do: event_name
      defp binding_event_name(_binding), do: nil

      defp binding_observes_events?(binding) do
        case binding_event_name(binding) do
          event_name when not is_nil(event_name) and is_atom(event_name) -> true
          _other -> false
        end
      end

      defp binding_observes_anything?(binding) do
        binding_observes_events?(binding) or binding_fact_endpoints(binding) != []
      end

      defp binding_fact_endpoints(%{facts: facts}) do
        facts
        |> Map.values()
        |> Enum.uniq()
      end

      defp binding_fact_endpoints(_binding), do: []

      defp master_backend(%Ogol.Hardware.EtherCAT{} = spec) do
        case transport_mode(spec) do
          :udp -> running_simulator_backend(spec)
          _other -> configured_backend(spec)
        end
      end

      defp master_start_opts(%Ogol.Hardware.EtherCAT{} = spec, backend) do
        [
          backend: backend,
          dc: nil,
          domains: runtime_domains(spec),
          slaves: spec.slaves,
          scan_stable_ms: scan_stable_ms(spec),
          scan_poll_ms: scan_poll_ms(spec),
          frame_timeout_ms: frame_timeout_ms(spec)
        ]
      end

      defp runtime_domains(%Ogol.Hardware.EtherCAT{domains: domains}) do
        Enum.map(domains, &domain_to_runtime/1)
      end

      defp domain_to_runtime(%Ogol.Hardware.EtherCAT.Domain{} = domain) do
        [
          id: domain.id,
          cycle_time_us: domain.cycle_time_us,
          miss_threshold: domain.miss_threshold,
          recovery_threshold: domain.recovery_threshold
        ]
      end

      defp transport_mode(%Ogol.Hardware.EtherCAT{transport: %{mode: mode}}), do: mode
      defp bind_ip(%Ogol.Hardware.EtherCAT{transport: %{bind_ip: bind_ip}}), do: bind_ip

      defp primary_interface(%Ogol.Hardware.EtherCAT{transport: %{primary_interface: interface}}),
        do: interface

      defp secondary_interface(
             %Ogol.Hardware.EtherCAT{transport: %{secondary_interface: interface}}
           ),
           do: interface

      defp scan_stable_ms(%Ogol.Hardware.EtherCAT{timing: %{scan_stable_ms: value}}), do: value
      defp scan_poll_ms(%Ogol.Hardware.EtherCAT{timing: %{scan_poll_ms: value}}), do: value
      defp frame_timeout_ms(%Ogol.Hardware.EtherCAT{timing: %{frame_timeout_ms: value}}), do: value

      defp running_simulator_backend(%Ogol.Hardware.EtherCAT{} = spec) do
        case Simulator.status() do
          {:ok, %SimulatorStatus{lifecycle: :running, backend: %Backend.Udp{} = backend}} ->
            {:ok, %{backend | bind_ip: bind_ip(spec)}}

          {:ok, %SimulatorStatus{lifecycle: :running, backend: %Backend.Raw{} = backend}} ->
            {:ok, backend}

          {:ok, %SimulatorStatus{lifecycle: :running, backend: %Backend.Redundant{} = backend}} ->
            {:ok, backend}

          {:ok, %SimulatorStatus{lifecycle: :running, backend: nil}} ->
            {:error, :simulator_backend_unknown}

          {:ok, %SimulatorStatus{lifecycle: :stopped}} ->
            {:error, :simulator_not_running}

          {:error, _reason} ->
            {:error, :simulator_not_running}
        end
      end

      defp configured_backend(%Ogol.Hardware.EtherCAT{} = spec) do
        case transport_mode(spec) do
          :udp ->
            {:ok, %Backend.Udp{host: @default_simulator_host, bind_ip: bind_ip(spec), port: 0}}

          :raw ->
            case primary_interface(spec) do
              interface when is_binary(interface) and byte_size(interface) > 0 ->
                {:ok, %Backend.Raw{interface: interface}}

              _other ->
                {:error, :missing_primary_interface}
            end

          :redundant ->
            case {primary_interface(spec), secondary_interface(spec)} do
              {primary, secondary}
              when is_binary(primary) and byte_size(primary) > 0 and is_binary(secondary) and
                     byte_size(secondary) > 0 ->
                {:ok,
                 %Backend.Redundant{
                   primary: %Backend.Raw{interface: primary},
                   secondary: %Backend.Raw{interface: secondary}
                 }}

              {_primary, _secondary} ->
                {:error, :missing_secondary_interface}
            end
        end
      end

      defp backend_port(%Backend.Udp{port: port}), do: port
      defp backend_port(_backend), do: nil
    end
    """
  end

  defp hardware_literal(%EtherCAT{} = hardware) do
    %EtherCAT{
      id: hardware.id,
      label: hardware.label,
      inserted_at: hardware.inserted_at,
      updated_at: hardware.updated_at,
      transport: hardware.transport,
      timing: hardware.timing,
      domains: hardware.domains,
      slaves: hardware.slaves,
      meta: %{}
    }
  end

  defp extract_hardware_term({:defmodule, _, [_module_ast, [do: body]]}) do
    forms = body_forms(body)

    case Enum.find_value(forms, &hardware_attribute_ast/1) do
      nil ->
        :unsupported

      definition_ast ->
        literal_from_ast(definition_ast)
    end
  end

  defp extract_hardware_term({:__block__, _, forms}) do
    forms
    |> Enum.filter(&match?({:defmodule, _, _}, &1))
    |> case do
      [form] -> extract_hardware_term(form)
      _ -> :unsupported
    end
  end

  defp extract_hardware_term(_other), do: :unsupported

  defp extract_module({:defmodule, _, [module_ast, [do: _body]]}), do: module_from_ast(module_ast)

  defp extract_module({:__block__, _, forms}) do
    forms
    |> Enum.filter(&match?({:defmodule, _, _}, &1))
    |> case do
      [form] -> extract_module(form)
      _ -> {:error, :unsupported}
    end
  end

  defp extract_module(_other), do: {:error, :unsupported}

  defp body_forms({:__block__, _, forms}), do: forms
  defp body_forms(form), do: [form]

  defp hardware_attribute_ast({:@, _, [{:hardware, _, [definition_ast]}]}), do: definition_ast
  defp hardware_attribute_ast(_other), do: nil

  defp module_from_ast({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}
  defp module_from_ast(atom) when is_atom(atom), do: {:ok, atom}
  defp module_from_ast(_other), do: {:error, :unsupported}

  defp hardware_from_term(%EtherCAT{} = hardware) do
    {:ok, normalize_ethercat_defaults(hardware)}
  end

  defp hardware_from_term(map) when is_map(map) do
    with {:ok, transport} <- normalize_transport(map),
         {:ok, timing} <- normalize_timing(map),
         {:ok, domains} <- normalize_domains(Map.get(map, :domains, Map.get(map, "domains", []))),
         {:ok, slaves} <- normalize_slaves(Map.get(map, :slaves, Map.get(map, "slaves", []))) do
      {:ok,
       normalize_ethercat_defaults(%EtherCAT{
         id: fetch_optional(map, :id, EtherCAT.artifact_id()),
         label: fetch_optional(map, :label, EtherCAT.default_label()),
         inserted_at: fetch_optional(map, :inserted_at, nil),
         updated_at: fetch_optional(map, :updated_at, nil),
         transport: transport,
         timing: timing,
         domains: domains,
         slaves: slaves,
         meta: fetch_optional(map, :meta, %{}) || %{}
       })}
    end
  end

  defp hardware_from_term(_other), do: :unsupported

  defp normalize_ethercat_defaults(%EtherCAT{} = hardware) do
    %EtherCAT{
      hardware
      | id: hardware.id || EtherCAT.artifact_id(),
        label:
          case hardware.label do
            label when is_binary(label) and label != "" -> label
            _other -> EtherCAT.default_label()
          end,
        meta: hardware.meta || %{}
    }
  end

  defp normalize_transport(%Transport{} = transport), do: {:ok, transport}

  defp normalize_transport(map) when is_map(map) do
    transport_value =
      Map.get(
        map,
        :transport,
        Map.get(map, "transport", Map.get(map, :mode, Map.get(map, "mode")))
      )

    with {:ok, mode} <- normalize_transport_mode(transport_value) do
      {:ok,
       %Transport{
         mode: mode,
         bind_ip: Map.get(map, :bind_ip, Map.get(map, "bind_ip")),
         primary_interface: Map.get(map, :primary_interface, Map.get(map, "primary_interface")),
         secondary_interface:
           Map.get(map, :secondary_interface, Map.get(map, "secondary_interface"))
       }}
    end
  end

  defp normalize_transport(_other), do: :unsupported

  defp normalize_transport_mode(value) when value in [:udp, :raw, :redundant], do: {:ok, value}
  defp normalize_transport_mode(_other), do: :unsupported

  defp normalize_timing(%Timing{} = timing), do: {:ok, timing}

  defp normalize_timing(map) when is_map(map) do
    scan_stable_ms = Map.get(map, :scan_stable_ms, Map.get(map, "scan_stable_ms"))
    scan_poll_ms = Map.get(map, :scan_poll_ms, Map.get(map, "scan_poll_ms"))
    frame_timeout_ms = Map.get(map, :frame_timeout_ms, Map.get(map, "frame_timeout_ms"))

    with {:ok, scan_stable_ms} <- positive_integer(scan_stable_ms),
         {:ok, scan_poll_ms} <- positive_integer(scan_poll_ms),
         {:ok, frame_timeout_ms} <- positive_integer(frame_timeout_ms) do
      {:ok,
       %Timing{
         scan_stable_ms: scan_stable_ms,
         scan_poll_ms: scan_poll_ms,
         frame_timeout_ms: frame_timeout_ms
       }}
    end
  end

  defp normalize_timing(_other), do: :unsupported

  defp normalize_domains(domains) when is_list(domains) do
    domains
    |> Enum.reduce_while({:ok, []}, fn domain, {:ok, acc} ->
      case normalize_domain(domain) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        :unsupported -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :unsupported -> :unsupported
    end
  end

  defp normalize_domains(_other), do: :unsupported

  defp normalize_domain(%Domain{} = domain), do: {:ok, domain}

  defp normalize_domain(domain) when is_list(domain) do
    normalize_domain(Enum.into(domain, %{}))
  end

  defp normalize_domain(domain) when is_map(domain) do
    with {:ok, id} <- fetch_atom(domain, :id),
         {:ok, cycle_time_us} <- fetch_positive_integer(domain, :cycle_time_us),
         {:ok, miss_threshold} <- fetch_positive_integer(domain, :miss_threshold),
         {:ok, recovery_threshold} <- fetch_positive_integer(domain, :recovery_threshold) do
      {:ok,
       %Domain{
         id: id,
         cycle_time_us: cycle_time_us,
         miss_threshold: miss_threshold,
         recovery_threshold: recovery_threshold
       }}
    end
  end

  defp normalize_domain(_other), do: :unsupported

  defp normalize_slaves(slaves) when is_list(slaves) do
    if Enum.all?(slaves, &match?(%SlaveConfig{}, &1)) do
      {:ok, slaves}
    else
      :unsupported
    end
  end

  defp normalize_slaves(_other), do: :unsupported

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_other), do: :unsupported

  defp fetch_atom(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_atom(value) -> {:ok, value}
      _ -> :unsupported
    end
  end

  defp fetch_positive_integer(map, key) do
    case fetch_optional(map, key, nil) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> :unsupported
    end
  end

  defp fetch_optional(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp literal_from_ast({:%, _, [module_ast, attrs_ast]}) do
    with {:ok, module} <- literal_from_ast(module_ast),
         {:ok, module} <- ensure_struct_module(module),
         {:ok, attrs} <- literal_from_ast(attrs_ast) do
      {:ok, struct(module, attrs)}
    else
      _ -> :unsupported
    end
  end

  defp literal_from_ast({:%{}, _, entries}) do
    Enum.reduce_while(entries, {:ok, %{}}, fn {key_ast, value_ast}, {:ok, acc} ->
      with {:ok, key} <- literal_from_ast(key_ast),
           {:ok, value} <- literal_from_ast(value_ast) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _ -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, %{__struct__: module} = attrs} when is_atom(module) ->
        case ensure_struct_module(module) do
          {:ok, module} -> {:ok, struct(module, Map.delete(attrs, :__struct__))}
          :error -> :unsupported
        end

      result ->
        result
    end
  end

  defp literal_from_ast({:{}, _, values}) do
    values
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      _ -> :unsupported
    end
  end

  defp literal_from_ast({:__aliases__, _, parts}), do: {:ok, Module.concat(parts)}

  defp literal_from_ast({:-, _, [value_ast]}) do
    with {:ok, value} <- literal_from_ast(value_ast),
         true <- is_number(value) do
      {:ok, -value}
    else
      _ -> :unsupported
    end
  end

  defp literal_from_ast(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value_ast, {:ok, acc} ->
      case literal_from_ast(value_ast) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        _ -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      _ -> :unsupported
    end
  end

  defp literal_from_ast(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case literal_from_ast(item) do
        {:ok, resolved} -> {:cont, {:ok, [resolved | acc]}}
        _ -> {:halt, :unsupported}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, values |> Enum.reverse() |> List.to_tuple()}
      _ -> :unsupported
    end
  end

  defp literal_from_ast(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value) or
              is_atom(value) or is_nil(value),
       do: {:ok, value}

  defp literal_from_ast(_other), do: :unsupported

  defp ensure_struct_module(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        if function_exported?(module, :__struct__, 0), do: {:ok, module}, else: :error

      _ ->
        :error
    end
  end
end
