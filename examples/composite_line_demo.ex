defmodule Ogol.Examples.CompositeLineDemo do
  @moduledoc """
  Composite in-memory line example using an explicit topology around several
  machine brains.

  Publicly, interact with the line through skills and status:

  - the line exposes public skills such as `start_cycle` and `release_line`
  - topology owns deployment, supervision, and target resolution
  - dependency state/signal bindings are an internal topology mechanism here, not
    the public composition model

  In IEx:

      iex -S mix phx.server
      demo = Ogol.Examples.CompositeLineDemo.boot!(signal_sink: self())
      {:ok, :ok} = Ogol.Examples.CompositeLineDemo.invoke(demo, :start_cycle)
      flush()
      LineController.status(:packaging_line)
      {:ok, :ok} = Ogol.Examples.CompositeLineDemo.invoke(demo, :release_line)
      flush()
      Ogol.Examples.CompositeLineDemo.stop(demo)
  """

  defmodule LineTopology do
    @moduledoc false

    use Ogol.Topology

    topology do
      root(:packaging_line)
    end

    machines do
      machine(:packaging_line, Ogol.Examples.CompositeLineDemo.LineController)
      machine(:feeder, Ogol.Examples.CompositeLineDemo.FeederMachine)
      machine(:clamp, Ogol.Examples.CompositeLineDemo.ClampMachine)
      machine(:inspector, Ogol.Examples.CompositeLineDemo.InspectorMachine)
    end

    observations do
      observe_state(:feeder, :presented, as: :feeder_ready)
      observe_signal(:feeder, :part_presented, as: :feeder_ready)
      observe_state(:clamp, :closed, as: :clamp_ready)
      observe_signal(:clamp, :clamp_closed, as: :clamp_ready)
      observe_signal(:inspector, :inspection_passed, as: :inspection_passed)
      observe_down(:feeder, as: :dependency_down)
      observe_down(:clamp, as: :dependency_down)
      observe_down(:inspector, as: :dependency_down)
    end
  end

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
      event(:close_requested, skill?: true)
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
      meaning("Line controller coordinating feeder, clamp, and inspector dependencies")
    end

    uses do
      dependency(:feeder, skills: [:feed_part, :reset], signals: [:part_presented])
      dependency(:clamp, skills: [:close_requested, :open], signals: [:clamp_closed])
      dependency(:inspector, skills: [:inspect, :reset], signals: [:inspection_passed])
    end

    boundary do
      request(:start_cycle)
      request(:release_line)
      event(:feeder_ready)
      event(:clamp_ready)
      event(:inspection_passed)
      event(:dependency_down)
      output(:busy?, :boolean, default: false)
      signal(:cycle_started)
      signal(:part_loaded)
      signal(:clamp_verified)
      signal(:cycle_completed)
      signal(:line_released)
      signal(:dependency_fault)
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
        invoke(:feeder, :feed_part)
        reply(:ok)
      end

      transition :feeding, :clamping do
        on({:event, :feeder_ready})
        guard(Ogol.Machine.Helpers.callback(:from_feeder?))
        signal(:part_loaded)
        invoke(:clamp, :close_requested)
      end

      transition :clamping, :inspecting do
        on({:event, :clamp_ready})
        guard(Ogol.Machine.Helpers.callback(:from_clamp?))
        signal(:clamp_verified)
        invoke(:inspector, :inspect)
      end

      transition :inspecting, :complete do
        on({:event, :inspection_passed})
        guard(Ogol.Machine.Helpers.callback(:from_inspector?))
        callback(:increment_completed_cycles)
        signal(:cycle_completed)
      end

      transition :complete, :idle do
        on({:request, :release_line})
        invoke(:clamp, :open)
        invoke(:feeder, :reset)
        invoke(:inspector, :reset)
        signal(:line_released)
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :release_line})
        invoke(:clamp, :open)
        invoke(:feeder, :reset)
        invoke(:inspector, :reset)
        signal(:line_released)
        reply(:ok)
      end

      transition :idle, :idle do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end

      transition :feeding, :idle do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end

      transition :clamping, :idle do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end

      transition :inspecting, :idle do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end

      transition :complete, :idle do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end
    end

    safety do
      always(Ogol.Machine.Helpers.callback(:cycle_counter_valid?))
    end

    def from_feeder?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :dependency and meta[:dependency] == :feeder and
        is_pid(meta[:dependency_pid])
    end

    def from_clamp?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :dependency and meta[:dependency] == :clamp and
        is_pid(meta[:dependency_pid])
    end

    def from_inspector?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :dependency and meta[:dependency] == :inspector and
        is_pid(meta[:dependency_pid])
    end

    def from_known_dependency?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :dependency and
        meta[:dependency] in [:feeder, :clamp, :inspector] and
        is_pid(meta[:dependency_pid])
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
    {:ok, topology} = LineTopology.start_link(opts)

    %{
      topology: topology,
      brain: LineTopology.brain_pid(topology),
      feeder: LineTopology.machine_pid(topology, :feeder),
      clamp: LineTopology.machine_pid(topology, :clamp),
      inspector: LineTopology.machine_pid(topology, :inspector)
    }
  end

  @spec invoke(demo() | pid(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(topology_or_demo, name, data \\ %{}, opts \\ [])

  def invoke(%{topology: topology}, name, data, opts) do
    invoke(topology, name, data, opts)
  end

  def invoke(topology, name, data, opts) when is_pid(topology) do
    Ogol.Runtime.Delivery.invoke(topology, name, data, opts)
  end

  @spec machine_pid(demo() | pid(), atom()) :: pid() | nil
  def machine_pid(%{topology: topology}, machine_name), do: machine_pid(topology, machine_name)

  def machine_pid(topology, machine_name) when is_pid(topology),
    do: LineTopology.machine_pid(topology, machine_name)

  @spec brain_pid(demo() | pid()) :: pid()
  def brain_pid(%{topology: topology}), do: brain_pid(topology)
  def brain_pid(topology) when is_pid(topology), do: LineTopology.brain_pid(topology)

  @spec stop(demo() | pid()) :: :ok
  def stop(%{topology: topology}), do: stop(topology)

  def stop(topology) when is_pid(topology) do
    GenServer.stop(topology, :shutdown)
    await_registry_clear([:packaging_line, :feeder, :clamp, :inspector])
  catch
    :exit, _reason -> :ok
  end

  defp await_registry_clear(names, attempts \\ 50)

  defp await_registry_clear(_names, 0), do: :ok

  defp await_registry_clear(names, attempts) do
    if Enum.all?(names, &(Ogol.Topology.Registry.whereis(&1) == nil)) do
      :ok
    else
      Process.sleep(10)
      await_registry_clear(names, attempts - 1)
    end
  end
end
