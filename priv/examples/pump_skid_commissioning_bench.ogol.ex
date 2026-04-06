defmodule Ogol.RevisionFile.OgolExamples.PumpSkidCommissioningBench do
  @revision %{
    kind: :ogol_revision,
    format: 2,
    app_id: "ogol_examples",
    revision: "pump_skid_commissioning_bench",
    title: "Pump Skid Commissioning Bench",
    exported_at: "2026-04-03T00:00:00Z",
    sources: [
      %{
        kind: :hardware,
        id: "ethercat",
        module: Ogol.Generated.Hardware.EtherCAT,
        digest: "0000000000000000000000000000000000000000000000000000000000000001",
        title: "Pump skid EtherCAT bench"
      },
      %{
        kind: :simulator_config,
        id: "ethercat",
        module: Ogol.Generated.Simulator.Config.EtherCAT,
        digest: "0000000000000000000000000000000000000000000000000000000000000002",
        title: "Pump skid EtherCAT simulator"
      },
      %{
        kind: :machine,
        id: "supply_valve",
        module: Ogol.Generated.Machines.SupplyValve,
        digest: "0000000000000000000000000000000000000000000000000000000000000003",
        title: "Supply isolation valve"
      },
      %{
        kind: :machine,
        id: "return_valve",
        module: Ogol.Generated.Machines.ReturnValve,
        digest: "0000000000000000000000000000000000000000000000000000000000000004",
        title: "Return isolation valve"
      },
      %{
        kind: :machine,
        id: "transfer_pump",
        module: Ogol.Generated.Machines.TransferPump,
        digest: "0000000000000000000000000000000000000000000000000000000000000005",
        title: "Transfer pump starter"
      },
      %{
        kind: :machine,
        id: "alarm_stack",
        module: Ogol.Generated.Machines.AlarmStack,
        digest: "0000000000000000000000000000000000000000000000000000000000000006",
        title: "Alarm stack"
      },
      %{
        kind: :sequence,
        id: "pump_skid_commissioning",
        module: Ogol.Generated.Sequences.PumpSkidCommissioning,
        digest: "0000000000000000000000000000000000000000000000000000000000000007",
        title: "Pump skid commissioning cycle"
      },
      %{
        kind: :topology,
        id: "pump_skid_bench",
        module: Ogol.Generated.Topologies.PumpSkidBench,
        digest: "0000000000000000000000000000000000000000000000000000000000000008",
        title: "Pump skid commissioning topology"
      }
    ]
  }

  def manifest do
    @revision
  end
end

defmodule Ogol.Generated.Hardware.EtherCAT do
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
  @hardware %Ogol.Hardware.EtherCAT{
    transport: %Ogol.Hardware.EtherCAT.Transport{
      mode: :raw,
      bind_ip: nil,
      primary_interface: "eth0",
      secondary_interface: nil
    },
    timing: %Ogol.Hardware.EtherCAT.Timing{
      scan_stable_ms: 20,
      scan_poll_ms: 10,
      frame_timeout_ms: 20
    },
    id: "pump_skid_bench",
    label: "Pump skid EtherCAT bench",
    domains: [
      %Ogol.Hardware.EtherCAT.Domain{
        id: :main,
        cycle_time_us: 1000,
        miss_threshold: 1000,
        recovery_threshold: 3
      }
    ],
    slaves: [
      %EtherCAT.Slave.Config{
        name: :coupler,
        driver: Ogol.Hardware.EtherCAT.Driver.EK1100,
        config: %{},
        process_data: :none,
        target_state: :op,
        sync: nil,
        health_poll_ms: 250
      },
      %EtherCAT.Slave.Config{
        name: :inputs,
        driver: Ogol.Hardware.EtherCAT.Driver.EL1809,
        config: %{},
        process_data: {:all, :main},
        target_state: :op,
        sync: nil,
        health_poll_ms: 250
      },
      %EtherCAT.Slave.Config{
        name: :outputs,
        driver: Ogol.Hardware.EtherCAT.Driver.EL2809,
        config: %{},
        process_data: {:all, :main},
        target_state: :op,
        sync: nil,
        health_poll_ms: 250
      }
    ],
    inserted_at: 1_775_180_000_000,
    updated_at: 1_775_180_000_000,
    meta: %{}
  }

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
  def child_specs(_opts \\ []) do
    hardware_id = id()

    {:ok,
     [
       Supervisor.child_spec({EtherCAT.Runtime, []},
         id: {:ogol_hardware_runtime, hardware_id},
         type: :supervisor
       ),
       Supervisor.child_spec(
         %{
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
      data: %{value: value, facts: %{fact_name => value}},
      meta: binding_meta |> Map.merge(meta) |> Map.put(:bus, :ethercat)
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

  defp secondary_interface(%Ogol.Hardware.EtherCAT{transport: %{secondary_interface: interface}}),
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

defmodule Ogol.Generated.Simulator.Config.EtherCAT do
  def simulator_opts do
    [
      devices: [
        EtherCAT.Simulator.Slave.from_driver(Ogol.Hardware.EtherCAT.Driver.EK1100,
          name: :coupler
        ),
        EtherCAT.Simulator.Slave.from_driver(Ogol.Hardware.EtherCAT.Driver.EL1809, name: :inputs),
        EtherCAT.Simulator.Slave.from_driver(Ogol.Hardware.EtherCAT.Driver.EL2809, name: :outputs)
      ],
      backend: {:udp, %{host: {127, 0, 0, 2}, port: 0}},
      topology: :linear,
      connections: [
        %{source: {:outputs, :ch1}, target: {:inputs, :ch1}},
        %{source: {:outputs, :ch2}, target: {:inputs, :ch2}},
        %{source: {:outputs, :ch3}, target: {:inputs, :ch3}},
        %{source: {:outputs, :ch4}, target: {:inputs, :ch4}},
        %{source: {:outputs, :ch5}, target: {:inputs, :ch5}},
        %{source: {:outputs, :ch6}, target: {:inputs, :ch6}}
      ]
    ]
  end
end

defmodule Ogol.Generated.Machines.SupplyValve do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  machine do
    name(:supply_valve)
    meaning("Supply isolation valve with wired open feedback")
  end

  boundary do
    request(:open)
    request(:close)
    request(:reset_fault)
    fact(:open_fb?, :boolean, default: false, public?: true)
    output(:open_cmd?, :boolean, default: false, public?: true)
    signal(:opened)
    signal(:closed)
    signal(:faulted)
  end

  states do
    state :closed do
      initial?(true)
      status("Closed")
      set_output(:open_cmd?, false)
    end

    state :opening do
      status("Opening")
      set_output(:open_cmd?, true)
      state_timeout(:open_timeout, 750)
    end

    state :open do
      status("Open")
      set_output(:open_cmd?, true)
    end

    state :closing do
      status("Closing")
      set_output(:open_cmd?, false)
      state_timeout(:close_timeout, 750)
    end

    state :faulted do
      status("Faulted")
      set_output(:open_cmd?, false)
    end
  end

  transitions do
    transition :closed, :open do
      on({:request, :open})
      guard(Ogol.Machine.Helpers.callback(:feedback_open_now?))
      signal(:opened)
      reply(:ok)
    end

    transition :closed, :opening do
      on({:request, :open})
      reply(:ok)
    end

    transition :open, :open do
      on({:request, :open})
      reply(:ok)
    end

    transition :opening, :open do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:feedback_open_now?))
      signal(:opened)
    end

    transition :opening, :faulted do
      on({:state_timeout, :open_timeout})
      signal(:faulted)
    end

    transition :open, :closed do
      on({:request, :close})
      guard(Ogol.Machine.Helpers.callback(:feedback_closed_now?))
      signal(:closed)
      reply(:ok)
    end

    transition :open, :closing do
      on({:request, :close})
      reply(:ok)
    end

    transition :closed, :closed do
      on({:request, :close})
      reply(:ok)
    end

    transition :closing, :closed do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:feedback_closed_now?))
      signal(:closed)
    end

    transition :closing, :faulted do
      on({:state_timeout, :close_timeout})
      signal(:faulted)
    end

    transition :faulted, :closed do
      on({:request, :reset_fault})
      reply(:ok)
    end
  end

  def feedback_open_now?(_delivered, data), do: Map.get(data.facts, :open_fb?, false)
  def feedback_closed_now?(_delivered, data), do: not Map.get(data.facts, :open_fb?, false)
end

defmodule Ogol.Generated.Machines.ReturnValve do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  machine do
    name(:return_valve)
    meaning("Return isolation valve with wired open feedback")
  end

  boundary do
    request(:open)
    request(:close)
    request(:reset_fault)
    fact(:open_fb?, :boolean, default: false, public?: true)
    output(:open_cmd?, :boolean, default: false, public?: true)
    signal(:opened)
    signal(:closed)
    signal(:faulted)
  end

  states do
    state :closed do
      initial?(true)
      status("Closed")
      set_output(:open_cmd?, false)
    end

    state :opening do
      status("Opening")
      set_output(:open_cmd?, true)
      state_timeout(:open_timeout, 750)
    end

    state :open do
      status("Open")
      set_output(:open_cmd?, true)
    end

    state :closing do
      status("Closing")
      set_output(:open_cmd?, false)
      state_timeout(:close_timeout, 750)
    end

    state :faulted do
      status("Faulted")
      set_output(:open_cmd?, false)
    end
  end

  transitions do
    transition :closed, :open do
      on({:request, :open})
      guard(Ogol.Machine.Helpers.callback(:feedback_open_now?))
      signal(:opened)
      reply(:ok)
    end

    transition :closed, :opening do
      on({:request, :open})
      reply(:ok)
    end

    transition :open, :open do
      on({:request, :open})
      reply(:ok)
    end

    transition :opening, :open do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:feedback_open_now?))
      signal(:opened)
    end

    transition :opening, :faulted do
      on({:state_timeout, :open_timeout})
      signal(:faulted)
    end

    transition :open, :closed do
      on({:request, :close})
      guard(Ogol.Machine.Helpers.callback(:feedback_closed_now?))
      signal(:closed)
      reply(:ok)
    end

    transition :open, :closing do
      on({:request, :close})
      reply(:ok)
    end

    transition :closed, :closed do
      on({:request, :close})
      reply(:ok)
    end

    transition :closing, :closed do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:feedback_closed_now?))
      signal(:closed)
    end

    transition :closing, :faulted do
      on({:state_timeout, :close_timeout})
      signal(:faulted)
    end

    transition :faulted, :closed do
      on({:request, :reset_fault})
      reply(:ok)
    end
  end

  def feedback_open_now?(_delivered, data), do: Map.get(data.facts, :open_fb?, false)
  def feedback_closed_now?(_delivered, data), do: not Map.get(data.facts, :open_fb?, false)
end

defmodule Ogol.Generated.Machines.TransferPump do
  use Ogol.Machine
  require Ogol.Machine.Helpers

  machine do
    name(:transfer_pump)
    meaning("Transfer pump starter with wired running feedback")
  end

  boundary do
    request(:start)
    request(:stop)
    request(:reset_fault)
    fact(:running_fb?, :boolean, default: false, public?: true)
    output(:run_cmd?, :boolean, default: false, public?: true)
    signal(:started)
    signal(:stopped)
    signal(:faulted)
  end

  states do
    state :stopped do
      initial?(true)
      status("Stopped")
      set_output(:run_cmd?, false)
    end

    state :starting do
      status("Starting")
      set_output(:run_cmd?, true)
      state_timeout(:start_timeout, 750)
    end

    state :running do
      status("Running")
      set_output(:run_cmd?, true)
    end

    state :stopping do
      status("Stopping")
      set_output(:run_cmd?, false)
      state_timeout(:stop_timeout, 750)
    end

    state :faulted do
      status("Faulted")
      set_output(:run_cmd?, false)
    end
  end

  transitions do
    transition :stopped, :running do
      on({:request, :start})
      guard(Ogol.Machine.Helpers.callback(:running_feedback_now?))
      signal(:started)
      reply(:ok)
    end

    transition :stopped, :starting do
      on({:request, :start})
      reply(:ok)
    end

    transition :running, :running do
      on({:request, :start})
      reply(:ok)
    end

    transition :starting, :running do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:running_feedback_now?))
      signal(:started)
    end

    transition :starting, :faulted do
      on({:state_timeout, :start_timeout})
      signal(:faulted)
    end

    transition :running, :stopped do
      on({:request, :stop})
      guard(Ogol.Machine.Helpers.callback(:stopped_feedback_now?))
      signal(:stopped)
      reply(:ok)
    end

    transition :running, :stopping do
      on({:request, :stop})
      reply(:ok)
    end

    transition :stopped, :stopped do
      on({:request, :stop})
      reply(:ok)
    end

    transition :stopping, :stopped do
      on({:hardware, :process_image})
      guard(Ogol.Machine.Helpers.callback(:stopped_feedback_now?))
      signal(:stopped)
    end

    transition :stopping, :faulted do
      on({:state_timeout, :stop_timeout})
      signal(:faulted)
    end

    transition :faulted, :stopped do
      on({:request, :reset_fault})
      reply(:ok)
    end
  end

  def running_feedback_now?(_delivered, data), do: Map.get(data.facts, :running_fb?, false)
  def stopped_feedback_now?(_delivered, data), do: not Map.get(data.facts, :running_fb?, false)
end

defmodule Ogol.Generated.Machines.AlarmStack do
  use Ogol.Machine

  machine do
    name(:alarm_stack)
    meaning("Three-output alarm stack with direct indication requests and wired feedback")
  end

  boundary do
    request(:show_running)
    request(:show_fault)
    request(:clear)
    fact(:green_fb?, :boolean, default: false, public?: true)
    fact(:red_fb?, :boolean, default: false, public?: true)
    fact(:horn_fb?, :boolean, default: false, public?: true)
    output(:green_cmd?, :boolean, default: false, public?: true)
    output(:red_cmd?, :boolean, default: false, public?: true)
    output(:horn_cmd?, :boolean, default: false, public?: true)
  end

  states do
    state :clear do
      initial?(true)
      status("Clear")
      set_output(:green_cmd?, false)
      set_output(:red_cmd?, false)
      set_output(:horn_cmd?, false)
    end

    state :running do
      status("Showing Running")
      set_output(:green_cmd?, true)
      set_output(:red_cmd?, false)
      set_output(:horn_cmd?, false)
    end

    state :alarm do
      status("Showing Alarm")
      set_output(:green_cmd?, false)
      set_output(:red_cmd?, true)
      set_output(:horn_cmd?, true)
    end
  end

  transitions do
    transition :clear, :running do
      on({:request, :show_running})
      reply(:ok)
    end

    transition :running, :running do
      on({:request, :show_running})
      reply(:ok)
    end

    transition :running, :alarm do
      on({:request, :show_fault})
      reply(:ok)
    end

    transition :clear, :alarm do
      on({:request, :show_fault})
      reply(:ok)
    end

    transition :alarm, :alarm do
      on({:request, :show_fault})
      reply(:ok)
    end

    transition :running, :clear do
      on({:request, :clear})
      reply(:ok)
    end

    transition :alarm, :clear do
      on({:request, :clear})
      reply(:ok)
    end

    transition :clear, :clear do
      on({:request, :clear})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Sequences.PumpSkidCommissioning do
  use Ogol.Sequence

  alias Ogol.Sequence.Expr
  alias Ogol.Sequence.Ref

  sequence do
    name(:pump_skid_commissioning)
    topology(Ogol.Generated.Topologies.PumpSkidBench)
    meaning("Commissioning cycle over a real EtherCAT loopback bench")

    proc :line_up do
      do_skill(:supply_valve, :open)

      wait(Ref.status(:supply_valve, :open_fb?),
        timeout: 2_000,
        fail: "supply valve feedback did not go high"
      )

      delay(500, meaning: "Hold supply valve open indication for verification")
      do_skill(:return_valve, :open)

      wait(Ref.status(:return_valve, :open_fb?),
        timeout: 2_000,
        fail: "return valve feedback did not go high"
      )

      delay(500, meaning: "Hold return valve open indication for verification")
    end

    proc :run_transfer do
      do_skill(:transfer_pump, :start)

      wait(Ref.status(:transfer_pump, :running_fb?),
        timeout: 2_000,
        fail: "pump did not report running"
      )

      delay(500, meaning: "Hold pump running indication for verification")
      do_skill(:alarm_stack, :show_running)

      wait(
        Expr.and_expr(
          Ref.status(:alarm_stack, :green_fb?),
          Expr.and_expr(
            Expr.not_expr(Ref.status(:alarm_stack, :red_fb?)),
            Expr.not_expr(Ref.status(:alarm_stack, :horn_fb?))
          )
        ),
        timeout: 2_000,
        fail: "running stack indication did not arrive"
      )

      delay(500, meaning: "Hold running stack indication for verification")
    end

    proc :trip_alarm do
      do_skill(:alarm_stack, :show_fault)

      wait(
        Expr.and_expr(
          Expr.not_expr(Ref.status(:alarm_stack, :green_fb?)),
          Expr.and_expr(
            Ref.status(:alarm_stack, :red_fb?),
            Ref.status(:alarm_stack, :horn_fb?)
          )
        ),
        timeout: 2_000,
        fail: "alarm stack indication did not arrive"
      )

      delay(500, meaning: "Hold alarm stack indication for verification")
    end

    proc :shutdown do
      do_skill(:transfer_pump, :stop)

      wait(Expr.not_expr(Ref.status(:transfer_pump, :running_fb?)),
        timeout: 2_000,
        fail: "pump did not stop"
      )

      delay(500, meaning: "Hold pump stopped indication for verification")
      do_skill(:alarm_stack, :clear)

      wait(
        Expr.and_expr(
          Expr.not_expr(Ref.status(:alarm_stack, :green_fb?)),
          Expr.and_expr(
            Expr.not_expr(Ref.status(:alarm_stack, :red_fb?)),
            Expr.not_expr(Ref.status(:alarm_stack, :horn_fb?))
          )
        ),
        timeout: 2_000,
        fail: "alarm stack did not clear"
      )

      delay(500, meaning: "Hold cleared stack indication for verification")
      do_skill(:return_valve, :close)

      wait(Expr.not_expr(Ref.status(:return_valve, :open_fb?)),
        timeout: 2_000,
        fail: "return valve did not close"
      )

      delay(500, meaning: "Hold return valve closed indication for verification")
      do_skill(:supply_valve, :close)

      wait(Expr.not_expr(Ref.status(:supply_valve, :open_fb?)),
        timeout: 2_000,
        fail: "supply valve did not close"
      )

      delay(500, meaning: "Hold supply valve closed indication for verification")
    end

    run(:line_up, meaning: "Open the fluid path")
    run(:run_transfer, meaning: "Start the transfer path")
    run(:trip_alarm, meaning: "Exercise the alarm indication")
    run(:shutdown, meaning: "Return the skid to safe idle")
  end
end

defmodule Ogol.Generated.Topologies.PumpSkidBench do
  use Ogol.Topology

  topology do
    strategy(:rest_for_one)
    meaning("Pump skid commissioning topology over wired EtherCAT IO")
  end

  machines do
    machine(
      :supply_valve,
      Ogol.Generated.Machines.SupplyValve,
      meaning: "Supply valve actuator",
      wiring: [
        outputs: [open_cmd?: {:outputs, :ch1}],
        facts: [open_fb?: {:inputs, :ch1}]
      ]
    )

    machine(
      :return_valve,
      Ogol.Generated.Machines.ReturnValve,
      meaning: "Return valve actuator",
      wiring: [
        outputs: [open_cmd?: {:outputs, :ch2}],
        facts: [open_fb?: {:inputs, :ch2}]
      ]
    )

    machine(
      :transfer_pump,
      Ogol.Generated.Machines.TransferPump,
      meaning: "Transfer pump motor starter",
      wiring: [
        outputs: [run_cmd?: {:outputs, :ch3}],
        facts: [running_fb?: {:inputs, :ch3}]
      ]
    )

    machine(
      :alarm_stack,
      Ogol.Generated.Machines.AlarmStack,
      meaning: "Alarm stack outputs",
      wiring: [
        outputs: [
          green_cmd?: {:outputs, :ch4},
          red_cmd?: {:outputs, :ch5},
          horn_cmd?: {:outputs, :ch6}
        ],
        facts: [
          green_fb?: {:inputs, :ch4},
          red_fb?: {:inputs, :ch5},
          horn_fb?: {:inputs, :ch6}
        ]
      ]
    )
  end
end
