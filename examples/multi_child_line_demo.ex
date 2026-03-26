defmodule Ogol.Examples.MultiChildLineDemo do
  @moduledoc """
  Composite in-memory line example with multiple child machine brains.

  This example shows the current topology model directly:

  - one parent `:gen_statem` brain coordinating the line
  - three child machine brains: feeder, clamp, and inspector
  - child state/signal bindings routed back into the parent as events
  - operator requests sent to the generated `Topology` shell

  In IEx:

      iex -S mix phx.server
      demo = Ogol.Examples.MultiChildLineDemo.boot!(signal_sink: self())
      Ogol.Examples.MultiChildLineDemo.request(demo, :start_cycle)
      flush()
      :sys.get_state(demo.brain)
      Ogol.Examples.MultiChildLineDemo.request(demo, :release_line)
      flush()
      Ogol.Examples.MultiChildLineDemo.stop(demo)
  """

  defmodule FeederMachine do
    @moduledoc false

    use Ogol.Machine

    machine do
      name(:line_feeder)
      meaning("Presents one part to the line and waits until the parent resets it")
    end

    boundary do
      request(:feed_part)
      request(:reset)
      output(:part_ready?, :boolean, default: false)
      signal(:part_presented)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:part_ready?, false)
      end

      state :presented do
        set_output(:part_ready?, true)
        signal(:part_presented)
      end
    end

    transitions do
      transition :idle, :presented do
        on({:request, :feed_part})
        reply(:ok)
      end

      transition :presented, :presented do
        on({:request, :feed_part})
        reenter?(true)
        reply(:ok)
      end

      transition :presented, :idle do
        on({:request, :reset})
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :reset})
        reply(:ok)
      end
    end
  end

  defmodule ClampMachine do
    @moduledoc false

    use Ogol.Machine

    machine do
      name(:line_clamp)
      meaning("Simple clamp that closes on an async event and reopens on request")
    end

    boundary do
      event(:close_requested)
      request(:open)
      output(:clamped?, :boolean, default: false)
      signal(:clamp_closed)
      signal(:clamp_opened)
    end

    states do
      state :open do
        initial?(true)
        set_output(:clamped?, false)
      end

      state :closed do
        set_output(:clamped?, true)
        signal(:clamp_closed)
      end
    end

    transitions do
      transition :open, :closed do
        on({:event, :close_requested})
      end

      transition :closed, :closed do
        on({:event, :close_requested})
        reenter?(true)
      end

      transition :closed, :open do
        on({:request, :open})
        signal(:clamp_opened)
        reply(:ok)
      end

      transition :open, :open do
        on({:request, :open})
        reply(:ok)
      end
    end
  end

  defmodule InspectorMachine do
    @moduledoc false

    use Ogol.Machine

    machine do
      name(:line_inspector)
      meaning("Deterministic inspector that marks the current part as passed")
    end

    boundary do
      request(:inspect)
      request(:reset)
      signal(:inspection_passed)
      output(:inspection_ready?, :boolean, default: false)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:inspection_ready?, true)
      end

      state :passed do
        set_output(:inspection_ready?, false)
        signal(:inspection_passed)
      end
    end

    transitions do
      transition :idle, :passed do
        on({:request, :inspect})
        reply(:ok)
      end

      transition :passed, :passed do
        on({:request, :inspect})
        reenter?(true)
        reply(:ok)
      end

      transition :passed, :idle do
        on({:request, :reset})
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :reset})
        reply(:ok)
      end
    end
  end

  defmodule LineController do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:packaging_line)
      meaning("Parent line controller coordinating feeder, clamp, and inspector children")
    end

    boundary do
      request(:start_cycle)
      request(:release_line)
      event(:feeder_ready)
      event(:clamp_ready)
      event(:inspection_passed)
      event(:child_down)
      output(:busy?, :boolean, default: false)
      signal(:cycle_started)
      signal(:part_loaded)
      signal(:clamp_verified)
      signal(:cycle_completed)
      signal(:line_released)
      signal(:child_fault)
    end

    memory do
      field(:completed_cycles, :integer, default: 0)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:busy?, false)
      end

      state :feeding do
        set_output(:busy?, true)
      end

      state :clamping do
        set_output(:busy?, true)
      end

      state :inspecting do
        set_output(:busy?, true)
      end

      state :complete do
        set_output(:busy?, false)
      end
    end

    transitions do
      transition :idle, :feeding do
        on({:request, :start_cycle})
        signal(:cycle_started)
        send_request(:feeder, :feed_part)
        reply(:ok)
      end

      transition :feeding, :clamping do
        on({:event, :feeder_ready})
        guard(Ogol.Machine.Helpers.callback(:from_feeder?))
        signal(:part_loaded)
        send_event(:clamp, :close_requested)
      end

      transition :clamping, :inspecting do
        on({:event, :clamp_ready})
        guard(Ogol.Machine.Helpers.callback(:from_clamp?))
        signal(:clamp_verified)
        send_request(:inspector, :inspect)
      end

      transition :inspecting, :complete do
        on({:event, :inspection_passed})
        guard(Ogol.Machine.Helpers.callback(:from_inspector?))
        callback(:increment_completed_cycles)
        signal(:cycle_completed)
      end

      transition :complete, :idle do
        on({:request, :release_line})
        send_request(:clamp, :open)
        send_request(:feeder, :reset)
        send_request(:inspector, :reset)
        signal(:line_released)
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :release_line})
        send_request(:clamp, :open)
        send_request(:feeder, :reset)
        send_request(:inspector, :reset)
        signal(:line_released)
        reply(:ok)
      end

      transition :idle, :idle do
        on({:event, :child_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_child?))
        signal(:child_fault)
      end

      transition :feeding, :idle do
        on({:event, :child_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_child?))
        signal(:child_fault)
      end

      transition :clamping, :idle do
        on({:event, :child_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_child?))
        signal(:child_fault)
      end

      transition :inspecting, :idle do
        on({:event, :child_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_child?))
        signal(:child_fault)
      end

      transition :complete, :idle do
        on({:event, :child_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_child?))
        signal(:child_fault)
      end
    end

    safety do
      always(Ogol.Machine.Helpers.callback(:cycle_counter_valid?))
    end

    children do
      child(:feeder, Ogol.Examples.MultiChildLineDemo.FeederMachine,
        state_bindings: [presented: :feeder_ready],
        signal_bindings: [part_presented: :feeder_ready],
        down_binding: :child_down,
        meaning: "Presents one part to the parent line"
      )

      child(:clamp, Ogol.Examples.MultiChildLineDemo.ClampMachine,
        state_bindings: [closed: :clamp_ready],
        signal_bindings: [clamp_closed: :clamp_ready],
        down_binding: :child_down,
        meaning: "Clamps the currently loaded part"
      )

      child(:inspector, Ogol.Examples.MultiChildLineDemo.InspectorMachine,
        signal_bindings: [inspection_passed: :inspection_passed],
        down_binding: :child_down,
        meaning: "Evaluates the clamped part and routes the result back"
      )
    end

    def from_feeder?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :child and meta[:child] == :feeder and is_pid(meta[:child_pid])
    end

    def from_clamp?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :child and meta[:child] == :clamp and is_pid(meta[:child_pid])
    end

    def from_inspector?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :child and meta[:child] == :inspector and is_pid(meta[:child_pid])
    end

    def from_known_child?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :child and meta[:child] in [:feeder, :clamp, :inspector] and
        is_pid(meta[:child_pid])
    end

    def increment_completed_cycles(_delivered, data, staging) do
      current = Map.get(data.fields, :completed_cycles, 0)

      next_data = %{
        staging.data
        | fields: Map.put(staging.data.fields, :completed_cycles, current + 1)
      }

      {:ok, %{staging | data: next_data}}
    end

    def cycle_counter_valid?(data) do
      value = Map.get(data.fields, :completed_cycles, 0)
      is_integer(value) and value >= 0
    end
  end

  @type demo :: %{
          topology: pid(),
          brain: pid(),
          feeder: pid() | nil,
          clamp: pid() | nil,
          inspector: pid() | nil
        }

  @spec boot!(keyword()) :: demo()
  def boot!(opts \\ []) do
    {:ok, topology} = LineController.Topology.start_link(opts)

    %{
      topology: topology,
      brain: LineController.Topology.brain_pid(topology),
      feeder: LineController.Topology.child_pid(topology, :feeder),
      clamp: LineController.Topology.child_pid(topology, :clamp),
      inspector: LineController.Topology.child_pid(topology, :inspector)
    }
  end

  @spec request(demo() | pid(), atom(), map(), map(), timeout()) :: term()
  def request(topology_or_demo, name, data \\ %{}, meta \\ %{}, timeout \\ 5_000)

  def request(%{topology: topology}, name, data, meta, timeout) do
    request(topology, name, data, meta, timeout)
  end

  def request(topology, name, data, meta, timeout) when is_pid(topology) do
    LineController.Topology.request(topology, name, data, meta, timeout)
  end

  @spec event(demo() | pid(), atom(), map(), map()) :: term()
  def event(topology_or_demo, name, data \\ %{}, meta \\ %{})

  def event(%{topology: topology}, name, data, meta) do
    event(topology, name, data, meta)
  end

  def event(topology, name, data, meta) when is_pid(topology) do
    LineController.Topology.event(topology, name, data, meta)
  end

  @spec child_pid(demo() | pid(), atom()) :: pid() | nil
  def child_pid(%{topology: topology}, child_name), do: child_pid(topology, child_name)

  def child_pid(topology, child_name) when is_pid(topology),
    do: LineController.Topology.child_pid(topology, child_name)

  @spec brain_pid(demo() | pid()) :: pid()
  def brain_pid(%{topology: topology}), do: brain_pid(topology)
  def brain_pid(topology) when is_pid(topology), do: LineController.Topology.brain_pid(topology)

  @spec stop(demo() | pid()) :: :ok
  def stop(%{topology: topology}), do: stop(topology)

  def stop(topology) when is_pid(topology) do
    GenServer.stop(topology, :shutdown)
  catch
    :exit, _reason -> :ok
  end
end
