defmodule Ogol.RevisionFile.Examples.PackagingLine do
  @revision %{
    kind: :ogol_revision,
    format: 2,
    app_id: "examples",
    revision: "packaging_line",
    title: "Packaging Line Example",
    exported_at: "2026-04-02T00:00:00Z",
    sources: [
      %{
        kind: :hardware,
        id: "ethercat",
        module: Ogol.Generated.Hardware.EtherCAT,
        digest: "cf6243a635d393aeee680607ce6550292ed07f5a4a342d19349e0d99e005c6ad",
        title: "EtherCAT Demo Ring"
      },
      %{
        kind: :machine,
        id: "clamp_station",
        module: Ogol.Generated.Machines.ClampStation,
        digest: "738b8d875c01d5e4d2c9d8d12a9c1422b080f18441509e48d7e1a33799970488",
        title: "Clamp station"
      },
      %{
        kind: :machine,
        id: "infeed_conveyor",
        module: Ogol.Generated.Machines.InfeedConveyor,
        digest: "52a0c4cccb69bfa5709db7b5467526a52f7d2475d30b92ee220302abba549211",
        title: "Infeed conveyor stop"
      },
      %{
        kind: :machine,
        id: "inspection_cell",
        module: Ogol.Generated.Machines.InspectionCell,
        digest: "b93bcfa34ef90ea38a07c261525408eefa855819d41cb0a2d255fa06f272101c",
        title: "Inspection cell coordinator"
      },
      %{
        kind: :machine,
        id: "inspection_station",
        module: Ogol.Generated.Machines.InspectionStation,
        digest: "a04bd08c7d80b7ce1837f9b90186acb91ef28a075251cef94968af8cffd6ca97",
        title: "Inspection station"
      },
      %{
        kind: :machine,
        id: "packaging_line",
        module: Ogol.Generated.Machines.PackagingLine,
        digest: "2dbba66bc5c627459d7d28db49c746668ca33d5fb71b8cf2123e69f4eeea897b",
        title: "Packaging Line coordinator"
      },
      %{
        kind: :machine,
        id: "palletizer_cell",
        module: Ogol.Generated.Machines.PalletizerCell,
        digest: "5c29537b08994a50f90ef8365983f1c0ddee2e5eeeb20ebdd551079deb729933",
        title: "Palletizer cell coordinator"
      },
      %{
        kind: :machine,
        id: "reject_gate",
        module: Ogol.Generated.Machines.RejectGate,
        digest: "f55ceb424cb76e6dd9112e77190c49c4481415d8ce4f1c4785868b081735138b",
        title: "Reject gate actuator"
      },
      %{
        kind: :topology,
        id: "packaging_line",
        module: Ogol.Generated.Topologies.PackagingLine,
        digest: "52001de28982f0221ce34063ed961987d2192ca922e4cf5db68c66e84f3c7e8e",
        title: "Packaging Line topology"
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
      mode: :udp,
      bind_ip: {127, 0, 0, 1},
      primary_interface: nil,
      secondary_interface: nil
    },
    timing: %Ogol.Hardware.EtherCAT.Timing{
      scan_stable_ms: 20,
      scan_poll_ms: 10,
      frame_timeout_ms: 20
    },
    id: "ethercat_demo",
    label: "EtherCAT Demo Ring",
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
    inserted_at: 1_775_128_395_861,
    updated_at: 1_775_128_447_989,
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

defmodule Ogol.Generated.Machines.ClampStation do
  use Ogol.Machine

  machine do
    name(:clamp_station)
    meaning("Clamp station")
  end

  boundary do
    request(:close)
    request(:open)
  end

  states do
    state(:open) do
      initial?(true)
      status("Open")
      meaning("Clamp released")
    end

    state(:closed) do
      status("Closed")
      meaning("Clamp engaged")
    end
  end

  transitions do
    transition(:closed, :open) do
      on({:request, :open})
      meaning("Release the clamp")
      reply(:ok)
    end

    transition(:open, :closed) do
      on({:request, :close})
      meaning("Clamp the staged part")
      reply(:ok)
    end

    transition(:open, :open) do
      on({:request, :open})
      meaning("Keep the clamp released")
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.InfeedConveyor do
  use Ogol.Machine

  machine do
    name(:infeed_conveyor)
    meaning("Infeed conveyor stop")
  end

  boundary do
    request(:feed_part)
    request(:reset)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Idle")
      meaning("Waiting for a part")
    end

    state(:positioned) do
      status("Positioned")
      meaning("Part staged")
    end
  end

  transitions do
    transition(:idle, :idle) do
      on({:request, :reset})
      meaning("Keep the infeed ready")
      reply(:ok)
    end

    transition(:idle, :positioned) do
      on({:request, :feed_part})
      meaning("Stage one part at the clamp stop")
      reply(:ok)
    end

    transition(:positioned, :idle) do
      on({:request, :reset})
      meaning("Clear the staged part")
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.InspectionCell do
  use Ogol.Machine

  machine do
    name(:inspection_cell)
    meaning("Inspection cell coordinator")
  end

  boundary do
    request(:reject)
    request(:reset)
    request(:start)
    signal(:faulted)
    signal(:rejected)
    signal(:started)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Idle")
    end

    state(:faulted) do
      status("Faulted")
    end

    state(:running) do
      status("Running")
    end
  end

  transitions do
    transition(:faulted, :idle) do
      on({:request, :reset})
      reply(:ok)
    end

    transition(:idle, :running) do
      on({:request, :start})
      reply(:ok)
    end

    transition(:running, :faulted) do
      on({:request, :reject})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.InspectionStation do
  use Ogol.Machine

  machine do
    name(:inspection_station)
    meaning("Inspection station")
  end

  boundary do
    request(:pass_part)
    request(:reject_part)
    request(:reset)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Ready")
      meaning("Waiting for inspection input")
    end

    state(:failed) do
      status("Rejected")
      meaning("Part rejected")
    end

    state(:passed) do
      status("Passed")
      meaning("Part accepted")
    end
  end

  transitions do
    transition(:failed, :idle) do
      on({:request, :reset})
      meaning("Prepare for the next inspection")
      reply(:ok)
    end

    transition(:idle, :failed) do
      on({:request, :reject_part})
      meaning("Reject the current part")
      reply(:ok)
    end

    transition(:idle, :idle) do
      on({:request, :reset})
      meaning("Keep the station ready")
      reply(:ok)
    end

    transition(:idle, :passed) do
      on({:request, :pass_part})
      meaning("Accept the current part")
      reply(:ok)
    end

    transition(:passed, :idle) do
      on({:request, :reset})
      meaning("Prepare for the next inspection")
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.PackagingLine do
  use Ogol.Machine

  machine do
    name(:packaging_line)
    meaning("Packaging Line coordinator")
  end

  boundary do
    request(:reset)
    request(:start)
    request(:stop)
    signal(:faulted)
    signal(:started)
    signal(:stopped)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Idle")
    end

    state(:faulted) do
      status("Faulted")
    end

    state(:running) do
      status("Running")
    end
  end

  transitions do
    transition(:faulted, :idle) do
      on({:request, :reset})
      reply(:ok)
    end

    transition(:idle, :running) do
      on({:request, :start})
      reply(:ok)
    end

    transition(:running, :idle) do
      on({:request, :stop})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.PalletizerCell do
  use Ogol.Machine

  machine do
    name(:palletizer_cell)
    meaning("Palletizer cell coordinator")
  end

  boundary do
    request(:arm)
    request(:reset)
    request(:stop)
    signal(:armed)
    signal(:faulted)
    signal(:stopped)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Idle")
    end

    state(:faulted) do
      status("Faulted")
    end

    state(:running) do
      status("Running")
    end
  end

  transitions do
    transition(:faulted, :idle) do
      on({:request, :reset})
      reply(:ok)
    end

    transition(:idle, :running) do
      on({:request, :arm})
      reply(:ok)
    end

    transition(:running, :idle) do
      on({:request, :stop})
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Machines.RejectGate do
  use Ogol.Machine

  machine do
    name(:reject_gate)
    meaning("Reject gate actuator")
  end

  boundary do
    request(:reject)
    request(:reset)
  end

  states do
    state(:idle) do
      initial?(true)
      status("Ready")
      meaning("Reject path clear")
    end

    state(:latched) do
      status("Rejecting")
      meaning("Reject gate active")
    end
  end

  transitions do
    transition(:idle, :idle) do
      on({:request, :reset})
      meaning("Keep the reject path clear")
      reply(:ok)
    end

    transition(:idle, :latched) do
      on({:request, :reject})
      meaning("Open the reject path")
      reply(:ok)
    end

    transition(:latched, :idle) do
      on({:request, :reset})
      meaning("Clear the reject latch")
      reply(:ok)
    end
  end
end

defmodule Ogol.Generated.Topologies.PackagingLine do
  use Ogol.Topology

  topology do
    strategy(:one_for_one)
    meaning("Packaging Line topology")
  end

  machines do
    machine(:packaging_line, Ogol.Generated.Machines.PackagingLine,
      restart: :permanent,
      meaning: "Packaging line coordinator"
    )
  end
end
