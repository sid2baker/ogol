defmodule Ogol.Examples.DeepDependencyLineDemo do
  @moduledoc """
  Flat-topology example with a deep dependency graph and repeated machine modules.

  This demo shows:

  - one explicit topology module
  - one root coordinator machine
  - one intermediate station machine
  - two named instances of the same clamp module

  The dependency graph is deep:

      deep_dependency_line -> pair_station -> left_clamp/right_clamp

  but the topology itself stays flat.

  In IEx:

      iex -S mix phx.server
      demo = Ogol.Examples.DeepDependencyLineDemo.boot!(signal_sink: self())
      {:ok, :ok} = Ogol.Examples.DeepDependencyLineDemo.invoke(demo, :start_cycle)
      flush()
      Ogol.status(:deep_dependency_line)
      Ogol.status(:pair_station)
      Ogol.status(:left_clamp)
      Ogol.status(:right_clamp)
      {:ok, :ok} = Ogol.Examples.DeepDependencyLineDemo.invoke(demo, :reset_line)
      Ogol.Examples.DeepDependencyLineDemo.stop(demo)
  """

  defmodule LineTopology do
    @moduledoc false

    use Ogol.Topology

    topology do
      root(:deep_dependency_line)
    end

    machines do
      machine(:deep_dependency_line, Ogol.Examples.DeepDependencyLineDemo.LineCoordinator)
      machine(:kit_feeder, Ogol.Examples.DeepDependencyLineDemo.KitFeeder)
      machine(:pair_station, Ogol.Examples.DeepDependencyLineDemo.PairStation)
      machine(:left_clamp, Ogol.Examples.DeepDependencyLineDemo.ClampUnit)
      machine(:right_clamp, Ogol.Examples.DeepDependencyLineDemo.ClampUnit)
    end

    observations do
      observe_state(:kit_feeder, :presented, as: :kit_ready)
      observe_signal(:kit_feeder, :kit_presented, as: :kit_ready)
      observe_status(:pair_station, :paired?, as: :station_ready)
      observe_down(:kit_feeder, as: :dependency_down)
      observe_down(:pair_station, as: :dependency_down)
    end
  end

  defmodule KitFeeder do
    @moduledoc false

    use Ogol.Machine

    machine do
      name(:kit_feeder)
      meaning("Presents one kit to the line coordinator")
    end

    boundary do
      request(:present_kit)
      request(:reset)
      output(:kit_ready?, :boolean, default: false, public?: true)
      signal(:kit_presented)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:kit_ready?, false)
      end

      state :presented do
        set_output(:kit_ready?, true)
        signal(:kit_presented)
      end
    end

    transitions do
      transition :idle, :presented do
        on({:request, :present_kit})
        reply(:ok)
      end

      transition :presented, :presented do
        on({:request, :present_kit})
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

  defmodule ClampUnit do
    @moduledoc false

    use Ogol.Machine

    machine do
      name(:clamp_unit)
      meaning("Reusable clamp module instantiated multiple times in one topology")
    end

    boundary do
      request(:close)
      request(:open)
      output(:closed?, :boolean, default: false, public?: true)
      signal(:closed)
    end

    states do
      state :open do
        initial?(true)
        set_output(:closed?, false)
      end

      state :closed do
        set_output(:closed?, true)
        signal(:closed)
      end
    end

    transitions do
      transition :open, :closed do
        on({:request, :close})
        reply(:ok)
      end

      transition :closed, :closed do
        on({:request, :close})
        reenter?(true)
        reply(:ok)
      end

      transition :closed, :open do
        on({:request, :open})
        reply(:ok)
      end

      transition :open, :open do
        on({:request, :open})
        reply(:ok)
      end
    end
  end

  defmodule PairStation do
    @moduledoc false

    use Ogol.Machine

    machine do
      name(:pair_station)
      meaning("Intermediate station that composes two repeated clamp dependencies")
    end

    uses do
      dependency(:left_clamp, skills: [:close, :open], status: [:closed?])
      dependency(:right_clamp, skills: [:close, :open], status: [:closed?])
    end

    boundary do
      request(:clamp_pair)
      request(:reset)
      output(:paired?, :boolean, default: false, public?: true)
      signal(:pair_clamped)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:paired?, false)
      end

      state :paired do
        set_output(:paired?, true)
        signal(:pair_clamped)
      end
    end

    transitions do
      transition :idle, :paired do
        on({:request, :clamp_pair})
        invoke(:left_clamp, :close)
        invoke(:right_clamp, :close)
        reply(:ok)
      end

      transition :paired, :paired do
        on({:request, :clamp_pair})
        reenter?(true)
        invoke(:left_clamp, :close)
        invoke(:right_clamp, :close)
        reply(:ok)
      end

      transition :paired, :idle do
        on({:request, :reset})
        invoke(:left_clamp, :open)
        invoke(:right_clamp, :open)
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :reset})
        invoke(:left_clamp, :open)
        invoke(:right_clamp, :open)
        reply(:ok)
      end
    end
  end

  defmodule LineCoordinator do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:deep_dependency_line)
      meaning("Root coordinator over a deeper machine dependency graph")
    end

    uses do
      dependency(:kit_feeder, skills: [:present_kit, :reset], signals: [:kit_presented])
      dependency(:pair_station, skills: [:clamp_pair, :reset], status: [:paired?])
    end

    boundary do
      request(:start_cycle)
      request(:reset_line)
      event(:kit_ready)
      event(:station_ready)
      event(:dependency_down)
      output(:busy?, :boolean, default: false, public?: true)
      signal(:cycle_started)
      signal(:kit_loaded)
      signal(:cycle_completed)
      signal(:line_reset)
      signal(:dependency_fault)
    end

    memory do
      field(:completed_cycles, :integer, default: 0, public?: true)
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

      state :complete do
        set_output(:busy?, false)
      end
    end

    transitions do
      transition :idle, :feeding do
        on({:request, :start_cycle})
        signal(:cycle_started)
        invoke(:kit_feeder, :present_kit)
        reply(:ok)
      end

      transition :feeding, :clamping do
        on({:event, :kit_ready})
        guard(Ogol.Machine.Helpers.callback(:from_kit_feeder?))
        signal(:kit_loaded)
        invoke(:pair_station, :clamp_pair)
      end

      transition :clamping, :complete do
        on({:event, :station_ready})
        guard(Ogol.Machine.Helpers.callback(:from_pair_station_status?))
        callback(:increment_completed_cycles)
        signal(:cycle_completed)
      end

      transition :complete, :idle do
        on({:request, :reset_line})
        invoke(:kit_feeder, :reset)
        invoke(:pair_station, :reset)
        signal(:line_reset)
        reply(:ok)
      end

      transition :idle, :idle do
        on({:request, :reset_line})
        invoke(:kit_feeder, :reset)
        invoke(:pair_station, :reset)
        signal(:line_reset)
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

      transition :complete, :idle do
        on({:event, :dependency_down})
        guard(Ogol.Machine.Helpers.callback(:from_known_dependency?))
        signal(:dependency_fault)
      end
    end

    safety do
      always(Ogol.Machine.Helpers.callback(:cycle_counter_valid?))
    end

    def from_kit_feeder?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :dependency and meta[:dependency] == :kit_feeder and
        is_pid(meta[:dependency_pid])
    end

    def from_pair_station_status?(%Ogol.Runtime.DeliveredEvent{data: data, meta: meta}, _status) do
      meta[:origin] == :dependency and meta[:dependency] == :pair_station and
        meta[:status] == :paired? and data[:value] == true and is_pid(meta[:dependency_pid])
    end

    def from_known_dependency?(%Ogol.Runtime.DeliveredEvent{meta: meta}, _data) do
      meta[:origin] == :dependency and meta[:dependency] in [:kit_feeder, :pair_station] and
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
          kit_feeder: pid() | nil,
          pair_station: pid() | nil,
          left_clamp: pid() | nil,
          right_clamp: pid() | nil
        }

  @spec boot!(keyword()) :: demo()
  def boot!(opts \\ []) do
    {:ok, topology} = LineTopology.start_link(opts)

    %{
      topology: topology,
      brain: LineTopology.brain_pid(topology),
      kit_feeder: LineTopology.machine_pid(topology, :kit_feeder),
      pair_station: LineTopology.machine_pid(topology, :pair_station),
      left_clamp: LineTopology.machine_pid(topology, :left_clamp),
      right_clamp: LineTopology.machine_pid(topology, :right_clamp)
    }
  end

  @spec invoke(demo() | pid(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def invoke(topology_or_demo, name, data \\ %{}, opts \\ [])

  def invoke(%{topology: topology}, name, data, opts), do: invoke(topology, name, data, opts)
  def invoke(topology, name, data, opts) when is_pid(topology), do: Ogol.invoke(topology, name, data, opts)

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
    await_registry_clear([:deep_dependency_line, :kit_feeder, :pair_station, :left_clamp, :right_clamp])
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
