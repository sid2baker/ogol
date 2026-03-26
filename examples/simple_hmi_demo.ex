defmodule Ogol.Examples.SimpleHmiDemo do
  @moduledoc """
  Minimal in-memory machine example for testing the HMI without EtherCAT.

  In IEx:

      iex -S mix phx.server
      {:ok, pid} = Ogol.Examples.SimpleHmiDemo.boot!()
      Ogol.request(pid, :start)
      Ogol.event(pid, :part_seen)
      Ogol.event(pid, :part_seen)
      :sys.get_state(pid)
      Ogol.Examples.SimpleHmiDemo.stop(pid)
  """

  defmodule LineMachine do
    @moduledoc false

    use Ogol.Machine
    require Ogol.Machine.Helpers

    machine do
      name(:simple_hmi_line)
      meaning("Tiny in-memory line machine for the LiveView HMI")
    end

    boundary do
      fact(:enabled?, :boolean, default: true)
      event(:part_seen)
      request(:start)
      request(:stop)
      output(:running?, :boolean, default: false)
      signal(:started)
      signal(:stopped)
      signal(:part_counted)
    end

    memory do
      field(:part_count, :integer, default: 0)
    end

    states do
      state :idle do
        initial?(true)
        set_output(:running?, false)
      end

      state :running do
        set_output(:running?, true)
      end
    end

    transitions do
      transition :idle, :running do
        on({:request, :start})
        guard(Ogol.Machine.Helpers.callback(:can_start?))
        signal(:started)
        reply(:ok)
      end

      transition :running, :running do
        on({:event, :part_seen})
        reenter?(true)
        callback(:count_part)
        signal(:part_counted)
      end

      transition :running, :idle do
        on({:request, :stop})
        signal(:stopped)
        reply(:ok)
      end
    end

    safety do
      always(Ogol.Machine.Helpers.callback(:machine_safe?))
    end

    def can_start?(_delivered, data), do: Map.get(data.facts, :enabled?, false)

    def count_part(_delivered, data, staging) do
      current = Map.get(data.fields, :part_count, 0)
      {:ok, %{staging | data: %{data | fields: Map.put(data.fields, :part_count, current + 1)}}}
    end

    def machine_safe?(data), do: is_integer(Map.get(data.fields, :part_count, 0))
  end

  @spec boot!(keyword()) :: {:ok, pid()} | {:error, term()}
  def boot!(opts \\ []) do
    LineMachine.start_link(opts)
  end

  @spec stop(pid()) :: true
  def stop(pid) when is_pid(pid) do
    Process.exit(pid, :shutdown)
  end
end
